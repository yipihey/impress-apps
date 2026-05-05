;; Minimal LaTeX highlights matching latex-lsp/tree-sitter-latex (master)
;; Uses only node types verified to exist in grammar.js.

;; Generic commands: \foo, \textbf, etc.
(command_name) @function

;; Comments
(comment) @comment
(block_comment) @comment
(line_comment) @comment

;; Punctuation / brackets
["[" "]" "{" "}"] @punctuation.bracket

;; Sectioning — heading colors
(part
  command: _ @keyword
  text: (curly_group
    (_) @markup.heading.1))

(chapter
  command: _ @keyword
  text: (curly_group
    (_) @markup.heading.2))

(section
  command: _ @keyword
  text: (curly_group
    (_) @markup.heading.2))

(subsection
  command: _ @keyword
  text: (curly_group
    (_) @markup.heading.3))

(subsubsection
  command: _ @keyword
  text: (curly_group
    (_) @markup.heading.4))

(paragraph
  command: _ @keyword
  text: (curly_group
    (_) @markup.heading.5))

(subparagraph
  command: _ @keyword
  text: (curly_group
    (_) @markup.heading.6))

;; Environments
(begin
  command: _ @keyword
  name: (curly_group_text
    (_) @module))

(end
  command: _ @keyword
  name: (curly_group_text
    (_) @module))

;; Citations and references
(citation
  command: _ @function.macro
  keys: (curly_group_text_list
    (_) @label))

(label_definition
  command: _ @function.macro
  name: (curly_group_label
    (_) @label))

(label_reference
  command: _ @function.macro
  names: (curly_group_label_list
    (_) @label))

;; Package/class inclusion
(package_include
  command: _ @keyword.control.import
  paths: (curly_group_path_list
    (_) @string))

(class_include
  command: _ @keyword.control.import
  path: (curly_group_path
    (_) @string))

;; Math environments — math color for content
(displayed_equation) @markup.math
(inline_formula) @markup.math

;; Parameters / placeholders
(placeholder) @variable.parameter

;; Bracket group arguments (optional args)
(brack_group_argc) @variable.parameter
