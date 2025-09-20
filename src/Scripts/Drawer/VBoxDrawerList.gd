class_name VBoxDrawerList
extends BaseVBoxMemoryList

# This class now inherits all functionality from BaseVBoxMemoryList
# No additional code needed - all shared functionality is in the base class

func _init(memory_tabs: BaseTabContainer, thread: MemoryThread, is_drawer: bool = true):
	super(memory_tabs, thread, is_drawer)
