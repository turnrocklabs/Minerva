extends RefCounted
## One parallel-chat run's bookkeeping. `ChatPane.execute_parallel_chat` makes
## one of these per run and binds it into every worker's response handler, so a
## run that was stopped can never pair its late response with — or count toward
## the completion of — the run that replaced it. Before this, all of it lived in
## pane-wide arrays that the runs shared.

## The chat this run was started on and the token `_begin_chat_turn` gave it.
## A response whose run no longer holds the chat's current token is stale.
var history: ChatHistory = null
var turn_token: int = -1

## Messages waiting to be picked up; each worker pops exactly one.
var inputs: Array[String] = []
## User messages whose request is under way, popped in order to pair with each
## arriving response.
var user_items: Array[ChatHistoryItem] = []

## How many workers this run started, and how many have delivered. The pending
## array cannot answer "is the run done": a worker appends its user item only
## once its own request is running, so the array is empty at the start too.
var expected: int = 0
var delivered: int = 0

## The rendered halves of this run's message pair and the slider ids stamped
## into its items, so two runs' bubbles never land in each other's containers.
var usr_messages_container: SliderContainer = null
var mdl_messages_container: SliderContainer = null
var user_slider_uuid: String = ""
var model_slider_uuid: String = ""
var multi_slider_uuid: String = ""

## Guards `inputs`, `user_items` and the counters: the workers are real threads.
var mutex: Mutex = Mutex.new()


## True once every worker of this run has delivered its response.
func is_complete() -> bool:
	return delivered >= expected
