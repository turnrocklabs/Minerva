class_name AudioToTexts
extends Node

var effect
var recording
var file_path = "res://VoiceAudio.wav"

# var icActive = preload("res://assets/icons/Microphone_active.png")
# var icStatic = preload("res://assets/icons/Microphone_statick.jpg")
var btn:Button
var btnStop:Button
# Variables for changing state
var is_converting:bool = false
var http_request

const WHISPER_API_URL = "https://api.openai.com/v1/audio/transcriptions"

var FieldForFilling#:TextEdit # needed to remove the type because this is getting used in lineEdits too

# Store the stop signal
var stop_signal:bool = false

func _ready():
	var idx = AudioServer.get_bus_index("Rec")
	effect = AudioServer.get_bus_effect(idx, 0)
	btnStop == null
func _StartConverting():
	stop_signal = false
	if effect.is_recording_active():
		btn.modulate = Color.WHITE
		recording = effect.get_recording()
		effect.set_recording_active(false)
		recording.save_to_wav(file_path)
		
		# Verify that the format is indeed WAV
		var file = FileAccess.open(file_path, FileAccess.READ)
		if file:
			# Check if stop signal is set
			if stop_signal:
				print("Conversion stopped")
				file.close()
				return

			# Read the first 4 bytes as a PackedByteArray
			var header = file.get_buffer(4) 
			# Convert the header to a String for comparison
			var header_str = header.get_string_from_utf8() 

			if header_str == "RIFF":
				var audio_data = file.get_buffer(file.get_length())
				file.close()

				# Check if stop signal is set
				if stop_signal:
					print("Conversion stopped")
					return
				
				# Make the API request
				http_request = HTTPRequest.new()
				http_request.use_threads = true
				add_child(http_request)
				http_request.connect("request_completed", self._on_request_completed)

				# Prepare the multipart/form-data request
				var boundary = "--------------------------" + str(Time.get_ticks_msec())
				var form_data = PackedByteArray()

				# Construct the form-data with correct headers and audio data
				form_data.append_array("--".to_ascii_buffer() + boundary.to_ascii_buffer() + "\r\n".to_ascii_buffer())
				form_data.append_array("Content-Disposition: form-data; name=\"model\"\r\n\r\n".to_ascii_buffer())
				form_data.append_array("whisper-1\r\n".to_ascii_buffer())

				form_data.append_array("--".to_ascii_buffer() + boundary.to_ascii_buffer() + "\r\n".to_ascii_buffer())
				form_data.append_array("Content-Disposition: form-data; name=\"file\"; filename=\"VoiceAudio.wav\"\r\n".to_ascii_buffer())
				form_data.append_array("Content-Type: audio/wav\r\n\r\n".to_ascii_buffer())
				form_data.append_array(header)
				form_data.append_array(audio_data)
				form_data.append_array("\r\n".to_ascii_buffer() + "--".to_ascii_buffer() + boundary.to_ascii_buffer() + "--\r\n".to_ascii_buffer())

				var headers = ["Authorization: Bearer " + SingletonObject.preferences_popup.get_api_key(SingletonObject.API_PROVIDER.OPENAI)
				,
				"Content-Type: multipart/form-data; boundary=" + boundary]
				# Send the request with the concatenated PoolByteArray
				http_request.request_raw(WHISPER_API_URL, headers, HTTPClient.METHOD_POST, form_data)
				btn.disabled = true
				btn.icon = ResourceLoader.load("res://assets/icons/loading_white-16-16.png")
				if btnStop != null:
					btnStop.disabled = false
			else:
				print("Invalid file format. Header: ", header_str)
		else:
			print("Failed to open audio file: ", file_path)
	else:
		effect.set_recording_active(true)

func _StopConverting():
	stop_signal = true
	# Stop recording if active
	if effect.is_recording_active():
		effect.set_recording_active(false)
		print("Recording stopped")
	
	# Disconnect HTTPRequest if it exists
	if http_request:
		http_request.disconnect("request_completed", self._on_request_completed)
		remove_child(http_request)
		http_request.queue_free()
		http_request = null
		print("HTTP request stopped")
	
	# Reset the button and other UI elements
	btn.disabled = false
	btn.modulate = Color.WHITE
	btn.icon = ResourceLoader.load("res://assets/icons/icons8-microphone-24.png")
	if btnStop != null:
		btnStop.disabled = true


func _on_request_completed(_result, response_code, _headers, body):
	if response_code == 200:
		var response_json = JSON.parse_string(body.get_string_from_utf8())
		# Check if the 'text' key exists in the response
		if response_json.has("text"):
			var transcription = response_json["text"]
			print("Transcription:", transcription)
			FieldForFilling.text += " " + transcription
			btn.disabled = false
			btn.modulate = Color.WHITE
			btn.icon = ResourceLoader.load("res://assets/icons/icons8-microphone-24.png")
		else:
			print("Unexpected response format:", response_json)
	else:
		print("Error:", response_code, "Response:", body.get_string_from_utf8())
