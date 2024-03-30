## ChatBox is a textedit with additional buttons and signals to make it work with memory/extractors/clipboard
class_name ChatBox
extends TextEdit

signal text_extracted(extracted: String, type: String)
signal memorize_text(text: String, type: String)

