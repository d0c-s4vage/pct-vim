
if exists("b:current_syntax")
  finish
endif

syntax match PctThreadName '\v^[^(]+ '
syntax match PctThreadFileInfo '\v\((.*:\d+)\)'
syntax match PctThreadId '\v\s*\[<\d+>\]'

highlight default link PctThreadId Comment
highlight default link PctThreadName Identifier
highlight default link PctThreadFileInfo Statement

let b:current_syntax = "pct_thread_tree"
