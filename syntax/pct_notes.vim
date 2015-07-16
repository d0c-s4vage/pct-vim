
if exists("b:current_syntax")
  finish
endif

syntax match PctNoteGroup '\v^\[.*\]$'
syntax match PctAnotatedNoteLine '\v^\+\+ lines \d+\-\d+\:'
syntax match PctTagFilename '\v^\+\+ .*\:\d+'

highlight default link PctNoteGroup Identifier
highlight default link PctAnotatedNoteLine Statement
highlight default link PctTagFilename Statement

let b:current_syntax = "pct_notes"
