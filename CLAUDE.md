I’m Imran, and you’re my agent. We’ll be working together a lot, so I thought it would be worth introducing myself.

I’m a former software engineer who mostly worked in C# around 2016. I’m also familiar with Python 3+ and know the basics of Godot.

I love to build. I focus on building complex things as simply as possible. I love finding ways to reduce complexity when solving problems.

I wanted to share some of my preferences so we can work together more effectively.

# Coding preferences — general

- Keep things simple. Channel “YAGNI” energy unless told otherwise.
- Don’t be afraid to propose bold ideas if they can meaningfully benefit our work! Rejected ideas aren’t a problem; sharing them is valuable.
- I use many tools that manage ownership of certain files. If it isn’t an ordinary source-code file, check whether an MCP-connected tool owns it. `.dct` files, for example, belong to Docket (or Minerva). Don’t manually modify tool-owned files unless you’re resolving a merge conflict.
- Tests are good! Focused tests are preferable to endless smoke tests or tests whose only purpose is to ensure an intentionally deleted feature stays deleted.
- I prefer a few broad tests rather than many narrow ones. I’m not a fan of mocks.
- Comments are a great way to clarify how code works! I value concise, meaningful comments. However, comments that mix project management with code are bad for readability. Long comments are also hard to read. Don’t comment every line, but feel free to describe how functions or classes are used above their definitions.
- Keep comments up to date! When making changes, make sure they remain in sync with the code.
- I have 3 PCs (Linux, Mac, Windows) I frequently switch between. Repos may be out of date -- so always pull when we start and make sure we're in either the "main" or "development" branches before we start. If we're not in one of those branches, warn me -- it may be intentional, or I might have just forgotten.
- When you run agents that change code, I prefer you run them serially and not in parallel. This reduces the chance that we "stomp" on work-in-progress (a problem we used to hit often). Reading code in parallel is fine, as is doing research, etc. Just code-change agents should be serialized.
- FCIBs (Foreign Checked-In Binaries) are bad. We shouldn't checkin executable programs or libraries, we should either build them from source, get them from their official or other well-known channels, or vendor them in if we need to patch / modify. Images and audio don't count -- this is about things we can compile. If there is no official or well-known place to get them, let me know and we'll solve that binary-by-binary.
- Git commit comments should explain project management state when it makes sense. Include things like DCR, bug, or other project-management tracking IDs if it makes sense.
- God files are bad, mmm-kay? God files make file reads take forever, and make it hard for you to figure out where to change code. This ends up slowing down all work over time. I like code files to remain in the 1-2 KLOC range. Before you commit, did your work take us into God territory? If so -- can you fix it now, or is the God file old and huge? If it's just crossing the boundary right now -- refactor right now. If it's been a God file for a while, file a work-item to refactor it.
- I really like DRY code. When planning to write code, see if there's ways to make utility classes / common classes / re-use code, or structure code for good re-use. There's a balance here between complexity and re-use, so weigh both sides. Simpler is better than DRY when they compete if simple is a lot simpler.

# Coding preferences — Godot-focused
- The "Any" type is disliked. Sometimes it's the right solution, but often, it's there because we got lazy. It's far better to be strongly typed when possible.
- Dynamically generated UI is hard for humans to debug. Prefer scenes when possible.
- Use Godot for syntax checks before running code. Syntax checks should not launch the application or otherwise affect the running project.
- Running Godot applications (beyond just syntax checks) from the command line may stop/terminate an application launched via the Godot editor. Check whether Godot is already running an application from the editor, and ask me before running another one.
- Be careful when running test cases: they may launch applications through the Godot command line. Check the test case before running it.
- Don't test too often or too broadly! Other systems are running tests on a decent frequency -- so only run the minimum tests to validate change, not entire suites, unless I explicitly ask.

# Questions are read only
- A question is a request for an answer, not for changes. Feel free to read, do web research, etc, to answer a question, but don't make code changes unless I ask imperatively.

# Work tracking
- I use the Docket work tracker for all work. Even small changes must have an item before changing code. If work is too small to track and has no docket item -- ask me for approval before making code changes. Make sure to use either docket app or minerva's integrated docket via MCP, not directly edit .dct files, when using docket. Prefer using docket app's MCP vs Minerva's when possible.

# Information tracking
- We have 2 different information tracking mechanisms -- nudge and docket. Nudge is memory backed and lasts until reboot, docket is file backed and lasts forever.
- Use nudge to have a compaction-resilient scratchpad that helps store useful, surprising, or error-correcting information.
- Use docket for long-term memory by using KB, Hints, or other information tracking types.
- A nudge item that is still true at the next startup has outlived "scratch" -- promote it to a docket hint (or KB) and delete it from nudge. Nudge should hold only the current session's working notes, not a backlog.
- When you startup or after compaction, check if you have any nudge items at all, and if there are any docket knowledge items from today or yesterday (work often crosses midnight).
