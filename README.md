pct-vim
=======

# PCT-VIM - Precise Code Tracking Vim plugin
by @d0c_s4vage

## Intro

This plugin is the vim implementation of the PCT method developed
by @tmanning. It is intended to assist in code auditing by enabling one to
annotate read-only source code from a text editor. This plugin
is the vim implementation. See @tmanning for the textmate implementation.

PCT uses an sqlite3 database to store and query audited ranges of code
and notes that were taken/added for line ranges.

## Getting started

Follow the steps below to initialize the database:

1. Install [dependencies](#dependencies)
2. Source pct.vim
3. Open a file in a project that you wish to audit
4. Run the command below to initialize the database:
		`:PctInit`
5. Begin auditing!

## Dependencies

* Vim
* Python
* `peewee` python module (`pip install peewee`)

## Key mappings

* Review
	* `[r`   -   mark the current/selected line(s) as having been reviewed
* Generic Comments (Annotations)
	* `[a`   -   annotate the current/selected line(s) with a single-line generic comment
	* `[A`   -   annotate the current/selected line(s) with a multi-line generic comment
* Findings
	* `[f`   -   annotate the current/selected line(s) with a single-line finding
	* `[F`   -   annotate the current/selected line(s) with a multi-line finding
* Todos
	* `[t`   -   annotate the current/selected line(s) with a single-line todo
	* `[T`   -   annotate the current/selected line(s) with a multi-line todo
* Reports/Listings
	* `[R`   -   toggle the report of the current project
	* `[h`   -   show a recent history of notes/reviewed source files
* Other
	* `[o`   -   open the file under the cursor in a new readonly tab (useful for reports)
* Annotation Navigation
	* `[n`   -   jump to the next annotation in the current file
	* `[N`   -   jump to the previous annotation in the current file

## Notes

Note that the only differentiation between annotations/findings/todos is the
existince of certain keywords in the annotation. Todos contain the word
"TODO" in the text, findings contain the word "FINDING" in the text, and
generic annotations don't contain either.

## Known Issues
* sometimes there are issues when viewing existing notes while scrolling through a split file

## Future

* ability to mark files as out-of-scope
* ability to edit/delete annotations

## Screenshots

Lines marked as reviewed

![Reviewed lines](http://i.imgur.com/xN8uduB.png)

A simple note/annotation

![Simple note/annotation](http://i.imgur.com/SHEMVEK.png)

A todo

![A todo](http://i.imgur.com/F3eqsU9.png)

A finding

![A finding](http://i.imgur.com/zr0xoDV.png)

Report and History

![PCT Report and History](http://i.imgur.com/m8G7eno.png)
