extends RefCounted
class_name VaultCrypto
## Pure crypto utilities for secret storage. No DB or state — all static.
## AES-256-CBC with PKCS7 padding, HMAC-SHA256, PBKDF2-HMAC-SHA256 key derivation.

const PBKDF2_ITERATIONS := 10000
const KEY_LENGTH := 32          # AES-256
const IV_LENGTH := 16           # AES block size
const SALT_LENGTH := 16
const BLOCK_SIZE := 16


static func generate_salt() -> PackedByteArray:
	return Crypto.new().generate_random_bytes(SALT_LENGTH)


static func generate_iv() -> PackedByteArray:
	return Crypto.new().generate_random_bytes(IV_LENGTH)


static func derive_key(password: String, salt: PackedByteArray) -> PackedByteArray:
	## PBKDF2-HMAC-SHA256 → 32-byte AES key.
	return _pbkdf2_sha256(password.to_utf8_buffer(), salt, PBKDF2_ITERATIONS, KEY_LENGTH)


static func encrypt(plaintext: String, key: PackedByteArray) -> Dictionary:
	## Returns {"ciphertext": PackedByteArray, "iv": PackedByteArray, "mac": PackedByteArray}.
	var iv := generate_iv()
	var padded := _pad_pkcs7(plaintext.to_utf8_buffer())
	var ciphertext := _aes_cbc_encrypt(padded, key, iv)
	var mac := _hmac_sha256(key, iv + ciphertext)
	return {"ciphertext": ciphertext, "iv": iv, "mac": mac}


static func decrypt(ciphertext: PackedByteArray, iv: PackedByteArray, mac: PackedByteArray, key: PackedByteArray) -> String:
	## Returns plaintext on success, "" on failure (bad MAC or padding).
	# Verify HMAC (encrypt-then-MAC)
	var expected_mac := _hmac_sha256(key, iv + ciphertext)
	if not _constant_time_compare(mac, expected_mac):
		return ""
	var decrypted := _aes_cbc_decrypt(ciphertext, key, iv)
	if decrypted.is_empty():
		return ""
	var unpadded := _unpad_pkcs7(decrypted)
	if unpadded.is_empty() and not decrypted.is_empty():
		# Padding was invalid
		return ""
	return unpadded.get_string_from_utf8()


static func compute_verify_hash(key: PackedByteArray) -> PackedByteArray:
	## HMAC-SHA256(key, "docket-vault-verify") — for wrong-password detection.
	return _hmac_sha256(key, "docket-vault-verify".to_utf8_buffer())


static func encrypt_2fa(plaintext: String, primary_key: PackedByteArray, secondary_key: PackedByteArray) -> Dictionary:
	## Double-encrypt: inner with secondary key, pack as blob, outer with primary key.
	## Returns {"ciphertext": PBA, "iv": PBA, "mac": PBA} (outer layer).
	var inner := encrypt(plaintext, secondary_key)
	var inner_blob: PackedByteArray = inner.iv + inner.mac + inner.ciphertext
	var inner_b64 := Marshalls.raw_to_base64(inner_blob)
	return encrypt(inner_b64, primary_key)


static func decrypt_2fa(ciphertext: PackedByteArray, iv: PackedByteArray, mac: PackedByteArray, primary_key: PackedByteArray, secondary_key: PackedByteArray) -> String:
	## Double-decrypt: outer with primary key, unpack blob, inner with secondary key.
	## Returns plaintext on success, "" on failure.
	var outer_plain := decrypt(ciphertext, iv, mac, primary_key)
	if outer_plain.is_empty():
		return ""
	var inner_data := Marshalls.base64_to_raw(outer_plain)
	if inner_data.is_empty() or inner_data.size() < 49:  # iv(16) + mac(32) + min 1 byte ciphertext
		return ""
	var inner_iv := inner_data.slice(0, 16)
	var inner_mac := inner_data.slice(16, 48)
	var inner_ct := inner_data.slice(48)
	return decrypt(inner_ct, inner_iv, inner_mac, secondary_key)


# -- PBKDF2-HMAC-SHA256 -------------------------------------------------------

static func _pbkdf2_sha256(password: PackedByteArray, salt: PackedByteArray, iterations: int, dk_len: int) -> PackedByteArray:
	## PBKDF2 with HMAC-SHA256 as the PRF.
	var hash_len := 32  # SHA-256 output
	var blocks_needed := ceili(float(dk_len) / float(hash_len))
	var dk := PackedByteArray()

	for block_idx in range(1, blocks_needed + 1):
		# INT(block_idx) — big-endian 4-byte encoding
		var int_bytes := PackedByteArray()
		int_bytes.resize(4)
		int_bytes[0] = (block_idx >> 24) & 0xFF
		int_bytes[1] = (block_idx >> 16) & 0xFF
		int_bytes[2] = (block_idx >> 8) & 0xFF
		int_bytes[3] = block_idx & 0xFF

		# U1 = HMAC(password, salt || INT(block_idx))
		var u := _hmac_sha256(password, salt + int_bytes)
		var result := u.duplicate()

		# U2..Uc
		for _i in range(1, iterations):
			u = _hmac_sha256(password, u)
			for j in range(result.size()):
				result[j] ^= u[j]

		dk.append_array(result)

	dk.resize(dk_len)
	return dk


# -- HMAC-SHA256 ---------------------------------------------------------------

static func _hmac_sha256(key_data: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	## HMAC-SHA256 per RFC 2104.
	var block_size := 64  # SHA-256 block size

	var k := key_data.duplicate()
	if k.size() > block_size:
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(k)
		k = ctx.finish()
	while k.size() < block_size:
		k.append(0)

	var o_key_pad := PackedByteArray()
	o_key_pad.resize(block_size)
	var i_key_pad := PackedByteArray()
	i_key_pad.resize(block_size)

	for i in range(block_size):
		o_key_pad[i] = k[i] ^ 0x5C
		i_key_pad[i] = k[i] ^ 0x36

	# Inner hash: SHA256(i_key_pad || data)
	var inner_ctx := HashingContext.new()
	inner_ctx.start(HashingContext.HASH_SHA256)
	inner_ctx.update(i_key_pad)
	inner_ctx.update(data)
	var inner_hash := inner_ctx.finish()

	# Outer hash: SHA256(o_key_pad || inner_hash)
	var outer_ctx := HashingContext.new()
	outer_ctx.start(HashingContext.HASH_SHA256)
	outer_ctx.update(o_key_pad)
	outer_ctx.update(inner_hash)
	return outer_ctx.finish()


# -- AES-256-CBC ---------------------------------------------------------------

static func _aes_cbc_encrypt(data: PackedByteArray, key: PackedByteArray, iv: PackedByteArray) -> PackedByteArray:
	## AES-256-CBC encrypt. Data must already be PKCS7-padded.
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_ENCRYPT, key, iv)
	var result := aes.update(data)
	aes.finish()
	return result


static func _aes_cbc_decrypt(data: PackedByteArray, key: PackedByteArray, iv: PackedByteArray) -> PackedByteArray:
	## AES-256-CBC decrypt. Returns padded plaintext.
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, key, iv)
	var result := aes.update(data)
	aes.finish()
	return result


# -- PKCS7 padding -------------------------------------------------------------

static func _pad_pkcs7(data: PackedByteArray) -> PackedByteArray:
	## PKCS7 pad to BLOCK_SIZE boundary.
	var pad_len := BLOCK_SIZE - (data.size() % BLOCK_SIZE)
	var padded := data.duplicate()
	for _i in range(pad_len):
		padded.append(pad_len)
	return padded


static func _unpad_pkcs7(data: PackedByteArray) -> PackedByteArray:
	## PKCS7 unpad. Returns empty array on invalid padding.
	if data.is_empty():
		return PackedByteArray()
	var pad_len: int = data[data.size() - 1]
	if pad_len < 1 or pad_len > BLOCK_SIZE:
		return PackedByteArray()
	if pad_len > data.size():
		return PackedByteArray()
	for i in range(data.size() - pad_len, data.size()):
		if data[i] != pad_len:
			return PackedByteArray()
	var result := data.duplicate()
	result.resize(data.size() - pad_len)
	return result


# -- Constant-time compare -----------------------------------------------------

static func _constant_time_compare(a: PackedByteArray, b: PackedByteArray) -> bool:
	## Constant-time comparison to avoid timing side-channels.
	if a.size() != b.size():
		return false
	var diff := 0
	for i in range(a.size()):
		diff |= a[i] ^ b[i]
	return diff == 0
