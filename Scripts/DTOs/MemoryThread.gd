class_name MemoryThread
extends RefCounted

var ThreadId: String
var ThreadName: String
var MemoryItemList: Array[MemoryItem]


# initialize with a new ThreadId
func _init(optional_threadId = null):
	if optional_threadId == null:
		# No threadId was provided, generate a new one
		var rng = RandomNumberGenerator.new() # Instantiate the RandomNumberGenerator
		rng.randomize() # Uses the current time to seed the random number generator
		var random_number = rng.randi() # Generates a random integer
		var hash256 = str(random_number).sha256_text()
		self.ThreadId = hash256
	else:
		# threadId was provided, use it
		self.ThreadId = optional_threadId
	pass

