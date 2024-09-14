# Minerva
Minvera is the Roman goddess of Inspiration.  This project, codename Minerva, will also be an app that helps you explore and automate stuff.

## Problem statement
We have LLM based AIs now.  They all kind of suck.  They're good at chatting, but not really doing stuff, and their error rate is high.  Hallucinations, catastrophic forgetting, and incorrect past weights plague their repsonses.  If you've ever tried to write modern Godot 4 with ChatGPT or even write python for modern Blender, you'll quickly see the errors.

This is not just in code writing -- the problems are everyplace in LLMs.  Even if you write a story, or try and create a CAD model, these mistakes happen.  They are generic problems.

## How Minerva helps
Minverva adds a note-taking system and (hopefully) some editors and task runners.  With Minverva, you can take some notes on how to correct the LLM, then ask the LLM to do something.  You can then manage the results from the LLM -- either by putting those into notes, or by putting them into your work product. 

## Features
- Cloud Light -- minimize interactions with the cloud / cloud services as much as possible.  Save files locally, use local resources, etc.
- Note area, with selectable notes.  (Only selected notes are submitted to the LLM, the rest are just for the human)
- (Eventually) support for multiple LLMs / providers.
	- Right now, only Google Vertex and Gemini 1.0 are supported.
