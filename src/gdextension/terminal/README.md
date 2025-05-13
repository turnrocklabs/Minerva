## Cloning the repo and submodules
When cloning the repo use: `git clone --recursive`

Or if you already cloned the repo, run these commands:  
`git submodule update --init`  
`git pull`  
`git submodule update --recursive`  


## Tools you need
Make sure you have python installed and SCons module  
`pip install SCons`  


## Compiling the GDExtension
cd into the `src/` directory and run:  
`python -m SCons platform={your_platform}`  
where `{your_platform}` is either `windows` or `linux`


After that you should be able to run/export the project just fine.