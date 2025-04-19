# Research Notes #
Having access to an advanced LLM / Agent system, I've noticed a few things.

- Embeddings and vectors are needed far less than peopleI thought.  Most workflows are narrow tasks that need a handful of articles, not searching across a DB.
    - But that is sometimes nice
- The different LLMs have different errors.
    - And in diffrent places.  ChatGPT forgets more than Claude Opus, but does induction better.
- There's no way to put multiple LLMs onto a problem..
- Costs!  I have no idea how much a query is going to cost.

# Scenarios? #
These are more like "I'd like to do this..."

## CAD ##
One things I'd like to do is CAD.  The LLMs have no concept of distance, and functions are needed.
"Human: here's a picture of a table.  It's 4 feet wide, 3 feet tall, and 3 feet deep.  Create a 3d model of it".

## 3D animation ##
I'd like to use standard characters and describe a scene/actions, and have the LLM do it.
"Human: Create a scene with Satoshi in a forest.  Have him pointing someplace.  Have Zoey nearby.  Have the camera put both in frame.  Animate Satoshi waving excitedly over 6 seconds."

## Social Media ##
Watch my feed for people talking about animation.
"Human: When people talk about animation, add a topical and insightful comment to their conversation.  You may search Google.com for anything that seems relevant, and use that as a basis."


## Fit and Finish TODOs ##
- Make a global theme system where we match colors / icons / etc to a theme of some sort.
