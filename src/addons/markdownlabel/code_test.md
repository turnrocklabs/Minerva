# Code Rendering Test

You can display code in-line by surrounding text with any number of backticks (\`), and you can display code in multiple lines (also called a fenced code block) by placing a line containing just three or more backticks (\`\`\`) or tildes (\~\~\~) above and below your code block.

## Examples:

### Code overview
```
Markdown text ................. -> BBCode equivalent
--------------------------------||------------------
The following is `in-line code` -> The following is [code]in-line code[/code]
This is also ``in-line code`` -> The following is [code]in-line code[/code]

~~~                  .......... -> [code]
This is a            .......... -> This is a
multiline codeblock  .......... -> multiline codeblock
~~~                  .......... -> [/code]

```

### Basic Block

```
python
print (\"Hello World\")
```


### Basic codeblock as llm formatted

```python
print (\"Hello World\")

```

test text

