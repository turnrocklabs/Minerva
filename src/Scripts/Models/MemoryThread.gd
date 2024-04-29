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

## Function:
# serialize the contents into a single structure
func Serialize() -> Dictionary:
	var serialized_memories: Array[Dictionary] = []

	for memory_item: MemoryItem in MemoryItemList:
		var serialized_memory = memory_item.Serialize()
		serialized_memories.append(serialized_memory)

	var save_dict: Dictionary = {
		"ThreadId": ThreadId,
		"ThreadName": ThreadName,
		"MemoryItemList": serialized_memories
	}

	return save_dict


## Function:
# deserialize the contents from dictionary
static func Deserialize(data: Dictionary) -> MemoryThread:
	var mt = MemoryThread.new(data.get("ThreadId"))

	mt.ThreadName = data.get("ThreadName")

	for mi_data: Dictionary in data.get("MemoryItemList", []):
		mt.MemoryItemList.append(MemoryItem.Deserialize(mi_data))
	
	return mt
