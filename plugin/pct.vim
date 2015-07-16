
function! DefinePct()
python3 <<EOF
# -*- coding: utf-8 -*-
from contextlib import contextmanager
import datetime
import glob
import os
import re
import sys
import sqlite3
import tempfile
import traceback

import vim

try:
	from peewee import *
except ImportError as e:
	print("Could not import peewee module, run 'pip install peewee'")

try:
	import arrow
except ImportError as e:
	arrow = None
	print("Could not import arrow, run 'pip install arrow' for pretty date-time output")

class PctModels:
	FileAccess = None
	Setting = None
	Scope = None
	ThreadNode = None
	Tag = None
	Note = None
	Reviewed = None
	File = None

DB = None
DB_PATH = None
DB_NAME = "pct2.sqlite"

def _input(message = 'input'):
	try:
		vim.command('call inputsave()')
		vim.command("let user_input = input('" + message + ": ')")
		vim.command('call inputrestore()')
		return vim.eval('user_input')
	except KeyboardInterrupt as e:
		return None

def human_date(dt):
	if arrow is None:
		return str(dt)
	else:
		return arrow.get(dt).humanize()

class Colors:
	HEADER = '\033[95m'
	OKBLUE = '\033[94m'
	OKGREEN = '\033[92m'
	WARNING = '\033[93m'
	FAIL = '\033[91m'
	ENDC = '\033[0m'

def buff_clear():
	vim.command("silent %delete _")

def buff_puts(msg, clear=True):
	vim.command("setlocal modifiable")
	if clear:
		buff_clear()
	count = 0
	for line in msg.split("\n"):
		vim.command("let tmp='" + line.replace("'", "' . \"'\" . '") + "'")
		if count == 0 and clear:
			vim.command("silent 0put=tmp")
		else:
			vim.command("silent put=tmp")
		count += 1

@contextmanager
def restore_cursor():
	yield
	vim.command("silent! wincmd p")

@contextmanager
def v_restore_cursor():
	yield
	vim.command('execute "normal! gv\\<ESC>"')

def mode():
	return vim.eval("mode()")

def is_visual(m=None):
	if m is None:
		m = mode()
	return m in ["v", "V", "CTRL-V"]

def winnr():
	"""
	"""
	return int(vim.eval("winnr()"))

def win_goto(nr):
	vim.command("execute '{nr}wincmd w'".format(nr=nr))

def buffwinnr(name):
	"""
	"""
	return int(vim.eval("bufwinnr('" + name + "')"))

def get_range(visual=None):
	"""Get the current start/stop line/col numbers
	"""
	if visual is None:
		# doesn't always work
		visual = is_visual()

	type_ = "'" if visual else "."
	start_cmd = 'getpos("{}<")'.format(type_)
	start_info = vim.eval(start_cmd)
	stop_cmd = 'getpos("{}>")'.format(type_)
	stop_info = vim.eval(stop_cmd)
	_,start_line,start_col,_ = start_info
	_,stop_line,stop_col,_ = stop_info
	return (start_line, stop_line, start_col, stop_col)

def get_buffnr(name):
	"""
	"""
	return int(vim.eval("bufnr('" + name + "')"))

def getline(line=None): 
	"""
	Return a line from the buffer named ``name``. If an actual line
	number is not specified, the current line will be returned
	"""
	this_buffnr = vim.current.buffer.number
	if line is None:
		line,_ = vim.current.window.cursor
	return vim.eval("getbufline({}, {})".format(this_buffnr, line))[0]

def buff_close(name, delete=False):
	"""
	Close the buffer with name `name`
	"""
	bufnr = buffwinnr(name)
	if bufnr == -1:
		return
	vim.command("execute '{nr}wincmd w'".format(nr=bufnr))

	if delete:
		try:
			vim.command("bd!")
		except:
			pass
	else:
		vim.command("close")

def buff_exists(name):
	"""
	Return true or false if the buffer named `name` exists
	"""
	return buffwinnr(name) != -1

def buff_goto(name):
	"""
	Goto to the buff with name `name`
	"""
	nr = buffwinnr(name)
	if nr == -1:
		return
	
	vim.command("{}wincmd w".format(nr))

def root_path():
	"""
	"""
	return os.path.abspath(os.path.dirname(DB.database))

def reduce_path(path):
	"""
	Return a path that does not have double separators, etc. Sometimes double
	separators occurs when using cscope/ctags/other tools
	"""
	return path.replace(os.path.sep * 2, os.path.sep)

def norm_path(path):
	"""
	Return a path that is relative to the database!
	"""
	res = os.path.relpath(path, os.path.dirname(DB.database))
	res = reduce_path(res)
	return res

def get_setting(name, default_val=None, raw=False):
	"""
	Get the setting value for setting named ``name`` from the db
	"""
	try:
		setting = PctModels.Setting.get(
			PctModels.Setting.name == name
		)
	except:
		if default_val is not None:
			setting = PctModels.Setting(name=name, value=default_val)
			setting.save()
			return default_val
		else:
			return None
	else:
		if raw:
			return setting
		else:
			return setting.value

def set_setting(name, value):
	"""
	Set (or create) the setting named ``name`` with value ``value``
	"""
	setting = get_setting(name, raw=True)
	setting.value = value
	setting.save()

def is_in_dir(dir_path, path):
	"""
	Return True/False if the ``path`` is found within the directory
	``dir_path``
	"""
	# can't be in it if it's not a directory
	if not os.path.isdir(dir_path):
		return False

	rel_path = os.path.relpath(path, dir_path)
	if rel_path.startswith(".."):
		return False
	return True

def is_file_in_scope(path):
	"""
	Return True/False if the path is in scope for the current project.

	It is assumed that path is within the project, and has already been normalized.
	"""
	default_scope = get_setting("default_scope", "blacklist")

	scopes = PctModels.Scope.select()
	for scope in scopes:
		if scope.include:
			if scope.path == path:
				return True
			elif is_in_dir(scope.path, path):
				return True
		elif is_in_dir(scope.path, path):
			return False

	if default_scope == "blacklist":
		# has not been blacklisted
		return True
	elif default_scope == "whitelist":
		# has not been whitelisted
		return False

def file_is_reviewable(path):
	"""
	Return True/False if the file exists and is in the current project,
	IF a valid DB exists
	"""
	if path is None:
		return False

	if isinstance(path, PctModels.File):
		return True

	if path is None:
		return False

	if not os.path.exists(path):
		return False
	
	if os.path.isdir(path):
		return False
	
	if not DB:
		return False
	
	if norm_path(path).startswith(".."):
		return False
	
	if not is_file_in_scope(path):
		err("not in scope")
		return False
	
	return True

def rev_norm_path(path):
	"""
	Return a normalized path relative to the cwd
	"""
	abs_path = os.path.abspath(os.path.join(os.path.dirname(DB.database), path))
	return os.path.relpath(abs_path, os.path.abspath(os.getcwd()))

def _msg(char, msg, pre="[", post="]", color=None):
	if False and color is not None:
		pre = color + pre
		post = post + Colors.ENDC

	for line in msg.split("\n"):
		print("{pre}{char}{post} {line}".format(
			pre=pre,
			char=char,
			post=post,
			line=line
		))

def err(msg):
	_msg("X", msg, color=Colors.FAIL)

def log(msg):
	_msg(" ", msg, color=Colors.OKBLUE)

def info(msg):
	_msg("+", msg, color=Colors.OKBLUE)

def warn(msg):
	_msg("!", msg, color=Colors.WARNING)

def ok(msg):
	_msg("✓", msg, color=Colors.OKGREEN)

def find_db(max_levels=15):
	db_name = DB_NAME
	curr_level = 0
	curr_path = db_name

	while curr_level < max_levels:
		if os.path.exists(curr_path):
			return curr_path
		curr_level += 1
		curr_path = os.path.join("..", curr_path)
	
	return None

def create_db(dest_path):
	global DB

	if dest_path is None:
		return

	DB = SqliteDatabase(dest_path, threadlocals=True)

	class BaseModel(Model):
		class Meta:
			database = DB
	
	class Setting(BaseModel):
		name		= CharField(unique=True)
		value		= CharField()
		created		= DateTimeField(default=datetime.datetime.utcnow)
	
	class Scope(BaseModel):
		path 		= CharField()
		include 	= BooleanField()
		created		= DateTimeField(default=datetime.datetime.utcnow)

	class File(BaseModel):
		path 		= CharField(unique=True)
		line_count	= IntegerField()
		created		= DateTimeField(default=datetime.datetime.utcnow)
	
	class FileAccess(BaseModel):
		file		= ForeignKeyField(File, related_name="accesses")
		line		= IntegerField()
		col			= IntegerField()
		created		= DateTimeField(default=datetime.datetime.utcnow)
	
	class Tag(BaseModel):
		name		= CharField()
		created		= DateTimeField(default=datetime.datetime.utcnow)
	
	class ThreadNode(BaseModel):
		file		= ForeignKeyField(File, related_name="threads", null=True)
		line		= IntegerField()
		tag			= ForeignKeyField(Tag, null=True, related_name="threads")
		name		= CharField()
		desc		= TextField()
		parent_node	= ForeignKeyField("self", null=True, related_name="children")
		created		= DateTimeField(default=datetime.datetime.utcnow)
	
	class Reviewed(BaseModel):
		file		= ForeignKeyField(File, related_name="reviews")
		line_start	= IntegerField() # 1-based line numbers
		line_end	= IntegerField() # 1-based line numbers
		created		= DateTimeField(default=datetime.datetime.utcnow)
	
	class Note(BaseModel):
		TYPE_NOTE = 0
		TYPE_TODO = 1
		TYPE_FINDING = 2

		file		= ForeignKeyField(File, related_name="notes")
		line_start	= IntegerField()
		line_end	= IntegerField()
		col_start	= IntegerField() # probably won't be used
		col_end		= IntegerField() # probably won't be used
		note		= TextField()
		tag			= ForeignKeyField(Tag, null=True, related_name="notes")
		note_type	= IntegerField() # 0-NOTE, 1-TODO, 2-FINDING
		thread_node	= ForeignKeyField(ThreadNode, related_name="notes")
		created		= DateTimeField(default=datetime.datetime.utcnow)
	
	PctModels.FileAccess = FileAccess
	PctModels.Setting = Setting
	PctModels.Scope = Scope
	PctModels.File = File
	PctModels.Tag = Tag
	PctModels.ThreadNode = ThreadNode
	PctModels.Reviewed = Reviewed
	PctModels.Note = Note

	tables = []
	for attr_name in PctModels.__dict__:
		attr = getattr(PctModels, attr_name)
		if type(attr) == type(BaseModel) and issubclass(attr, BaseModel):
			tables.append(attr)
		
	DB.connect()
	try:
		DB.create_tables(tables)
	except Exception as e:
		if "already exists" in str(e):
			pass
		else:
			raise

def prompt_for_db_path():
	warn("Could not find the database, where should it be created?")

	curr_path = os.path.join(os.getcwd(), "HACK")
	opts = []
	old_path = None
	while len(opts) < 7 and old_path != curr_path:
		old_path = curr_path
		curr_path = os.path.abspath(os.path.join(curr_path, ".."))
		db_path = os.path.join(curr_path, DB_NAME)
		opts.append(db_path)

	warn("Annotation location options:")
	for x in range(len(opts)):
		opt = opts[x]
		warn("  %s - %s" % (x, opt))
	
	choice = _input("Where would you like to create the database? (0-%d)" % (len(opts)-1))
	warn("")

	try:
		choice = int(choice)
	except:
		err("Invalid choice")
		return

	if not (0 <= choice < len(opts)):
		err("Invalid choice")
		return None
	
	return opts[choice]

def init_db(create=True):
	"""
	"""
	global THREAD_TREE_INFO

	found_db = None
	if not create:
		found_db = find_db()
	if found_db is None and create:
		db_path = prompt_for_db_path()

		if db_path is None:
			err("Invalid db path")
			return

		info("Using database at {}".format(db_path))
		found_db = db_path

	if create or found_db is not None:
		create_db(found_db)
		ok("found annotations database at %s" % found_db)
		vim.command("call DefineAutoCommands()")

		try:
			root = PctModels.ThreadNode.get(
				PctModels.ThreadNode.name == "ROOT" and PctModels.ThreadNode.parent_node == None
			)
		except:
			root = PctModels.ThreadNode(
				name		= "ROOT",
				parent_node	= None,
				tag			= None,
				file		= None,
				line		= -1,
				desc		= ""
			)
			root.save()

		# explicitly expand the root as the default
		THREAD_TREE_INFO[root.id] = "expand"
		_curr_thread(root)

# ----------------------------------------------
# ----------------------------------------------
# ----------------------------------------------
# ----------------------------------------------
# ----------------------------------------------

def get_tag(name=None, create=True):
	if name is not None and isinstance(name, PctModels.Tag):
		return name

	if name is None:
		name = vim.eval("expand('<cword>')")

	try:
		tag = PctModels.Tag.get(
			PctModels.Tag.name == name
		)
		return tag
	except:
		# sanity check so tags aren't being created for parens and such
		if create and re.match(r'^[_a-zA-Z][a-zA-Z_0-9]*', name) is not None:
			tag = PctModels.Tag(name = name)
			tag.save()
			return tag
		else:
			return None

def get_file_tags():
	curr_file_name = vim.current.buffer.name
	curr_file = get_file(curr_file_name)
	return curr_file.tags

def get_file_notes():
	curr_file_name = vim.current.buffer.name
	curr_file = get_file(curr_file_name)
	return curr_file.notes

def highlight_noted_tags():
	# we basically want all tags with notes/threads

	tags = set()
	
	for note in PctModels.Note.select():
		if note.tag is None:
			continue
		tags.add(note.tag.name)

	if len(tags) == 0:
		return

	regex = "\\v({})".format(
		"|".join(["<{}>".format(tag) for tag in tags])
	)
	vim.command("match tag_is_noted /{}/".format(regex))

def process_buff_enter():
	curr_file = vim.current.buffer.name

	if not file_is_reviewable(curr_file):
		return

	file_ = get_file()

	highlight_noted_tags()
	show_current_notes()
	show_file_signs(file_)

	# TODO revisit this?
	# we are AUDITING, not editing code
	vim.command("set ro")
	vim.command("set nomodifiable")

def process_new_buffer():
	# use this instead of `expand("%")`!!! % doens't work with BufAdd
	curr_file = vim.eval("expand('<afile>')")

	if not file_is_reviewable(curr_file):
		return

	# TODO revisit this?
	# we are AUDITING, not editing code
	vim.command("set ro")
	vim.command("set nomodifiable")

	# do not add files that are outside of the current project!
	if not file_is_reviewable(curr_file):
		return
	
	this_file = get_file(curr_file, create_access=True)
	show_file_signs(this_file)

def process_cursor_moved():
	curr_file = vim.current.buffer.name

	if not file_is_reviewable(curr_file):
		return
	
	show_current_notes()
	return

	tag = get_tag(create=False)
	if tag is None:
		return
	
	notes = list(tag.notes)
	if len(notes) > 0:
		res = ""
		for note in tag.notes:
			res += note.note
		print(res)

#----------
# History
#----------

HISTORY_NAME = "__PCT_HISTORY__"
def toggle_history():
	if buff_exists(HISTORY_NAME):
		buff_close(HISTORY_NAME)
		return
	else:
		show_history()

def show_history(limit=100, reverse=True):
	all_items = \
		list(PctModels.Note.select()) + \
		list(PctModels.Reviewed.select()) + \
		list(PctModels.ThreadNode.select()) + \
		list(PctModels.FileAccess.select())
	
	output = []
	sorted_items = sorted(all_items, key=lambda x: x.created, reverse=reverse)
	for item in sorted_items:
		line = getattr(item, "line", None)
		if line is None:
			line = getattr(item, "line_start", None)
		if item.file is None:
			continue
		output.append(
			"++ {}{} - {} [{}]".format(
				rev_norm_path(item.file.path),
				":{}".format(line) if line is not None else "",
				item.__class__.__name__,
				item.id
			)
		)
		output.append("    " + human_date(item.created))
		if isinstance(item, PctModels.Note):
			if item.tag is not None:
				output.append("    tag: {}".format(item.tag.name))
			output.append("\n".join("    {}".format(x) for x in item.note.split("\n")))
	
	create_scratch(
		"\n".join(output),
		fit_to_contents=False,
		return_to_orig=False,
		scratch_name=HISTORY_NAME,
		syntax="pct_notes",
		wrap=False
	)

	vim.command("normal! gg")

#----------
# Threads
#----------

THREADS = {
	# the current thread
	"current": None,
	
	# used for switching between threads, not creating a new thread node
	"last": None
}

def _curr_thread(val=None):
	global THREADS
	if val is None:
		return THREADS["current"]
	else:
		THREADS["current"] = val

def _last_thread(val=None):
	global THREADS
	if val is None:
		return THREADS["last"]
	else:
		THREADS["last"] = val

def _switch_thread(new_thread):
	global THREADS
	THREADS["last"] = THREADS["current"]
	THREADS["current"] = new_thread

def get_thread_from_tree(line=None):
	if line is None:
		line = getline()
	match = re.match(r'^.*\[(\d+)\]$', line)
	if match is None:
		return
	thread_node_id = int(match.group(1))

	new_thread = PctModels.ThreadNode.get(PctModels.ThreadNode.id == thread_node_id)
	return new_thread

def switch_thread():
	new_thread = get_thread_from_tree()
	_switch_thread(new_thread)
	update_thread_tree_highlight()

	info("switched to thread '{}'".format(new_thread.name))

	return new_thread

def open_thread_stay():
	open_thread()
	vim.command("silent! wincmd p")

def open_thread():
	new_thread = switch_thread()

	# should only be possible for the root node
	if new_thread.file is None:
		return

	rel_path = rev_norm_path(new_thread.file.path)
	bufnr = buffwinnr(rel_path)
	if bufnr == -1:
		vim.command("badd " + rel_path.replace(" ", "\\ "))
		vim.command("silent! wincmd p")
		bufnr = get_buffnr(rel_path)
		try:
			vim.command("b" + str(bufnr))
		except:
			pass
		bufnr = buffwinnr(rel_path)
	
	win_goto(bufnr)
	vim.current.window.cursor = (new_thread.line,0)
	vim.command("silent! normal! zz<CR>")

def open_thread_fold():
	global THREAD_TREE_INFO

	thread = get_thread_from_tree()
	THREAD_TREE_INFO[thread.id] = "expand"

	update_thread_tree()

def close_thread_fold():
	global THREAD_TREE_INFO

	thread = get_thread_from_tree()
	THREAD_TREE_INFO[thread.id] = "collapse"

	update_thread_tree()

def toggle_thread_fold():
	global THREAD_TREE_INFO

	thread = get_thread_from_tree()
	if THREAD_TREE_INFO.setdefault(thread.id, "default") in ["collapse", "default"]:
		open_thread_fold()
	else:
		close_thread_fold()

def open_all_thread_folds():
	for k in THREAD_TREE_INFO.keys():
		THREAD_TREE_INFO[k] = "expand"

	update_thread_tree()

def close_all_thread_folds():
	for k in THREAD_TREE_INFO.keys():
		THREAD_TREE_INFO[k] = "collapse"

	update_thread_tree()

def show_thread_notes():
	pass

def map_threadtree_keys():
	keymap = [
		("thread notes",	["[n"],						show_thread_notes),
		("jump",			["<CR>"],					open_thread),
		("jump-stay",		["<SPACE>"],				open_thread_stay),
		("switch",			["<TAB>"],					switch_thread),
		("openfold",		["+", "<kPlus>", "zo"],		open_thread_fold),
		("closefold",		["-", "<kMinus>", "zc"],	close_thread_fold),
		("togglefold",		["o", "za"],				toggle_thread_fold),
		("openallfolds",	["*", "<kMultiply>", "zR"],	open_all_thread_folds),
		("closeallfolds",	["=", "zM"],				close_all_thread_folds),
	]

	for mapname, keys, func in keymap:
		for key in keys:
			vim.command("nnoremap <script> <silent> <buffer> {} :py3 {}()<CR>".format(
				key,
				func.__name__
			))

THREAD_TREE_NAME = "__PCT_THREADS__"
def toggle_thread_tree():
	if buff_exists(THREAD_TREE_NAME):
		buff_close(THREAD_TREE_NAME)
		return
	else:
		show_thread_tree()

# defaults to all nodes being collapsed
THREAD_TREE_INFO = {}
def show_thread_tree(return_to_orig=False):
	global THREAD_TREE_INFO

	root_threads = PctModels.ThreadNode.select().where(
		PctModels.ThreadNode.parent_node == None
	)

	contents = []
	for root_thread in root_threads:
		if root_thread is None:
			continue
		contents.append(get_thread_node_lines(root_thread))

	if buff_exists(THREAD_TREE_NAME):
		win_goto(buffwinnr(THREAD_TREE_NAME))
		buff_puts("\n".join(contents))
		if return_to_orig:
			vim.command("silent! wincmd p")
	else:
		create_scratch(
			"\n".join(contents),
			fit_to_contents=False,
			return_to_orig=return_to_orig,
			scratch_name=THREAD_TREE_NAME,
			syntax="pct_thread_tree",
			window_pos="left",
			#width=15, # actual number of vertical lines
			#vertical=False
		)
		map_threadtree_keys()
	
	update_thread_tree_highlight()

def update_thread_tree_highlight():
	curr_thread = _curr_thread()
	vim.command("match none")
	vim.command("match current_thread /\\v{}.*\\[{}\\]/".format(
		curr_thread.name,
		curr_thread.id
	))

def update_thread_tree():
	buffnr = buffwinnr(THREAD_TREE_NAME)
	if buffnr == -1:
		return
	
	#with restore_cursor():
	if buffnr == buffwinnr(vim.current.buffer.name):
		cursor = vim.current.window.cursor
		show_thread_tree(return_to_orig=False)
		vim.current.window.cursor = cursor
	else:
		show_thread_tree(return_to_orig=True)
	
	update_thread_tree_highlight()

def is_in_curr_thread_path(thread_node):
	curr_node = _curr_thread()
	curr_node = curr_node.parent_node
	while curr_node is not None and curr_node.parent_node is not None:
		if curr_node.id == thread_node.id:
			return True
		curr_node = curr_node.parent_node
	return False

def get_thread_node_lines(node, level=0):
	if node.children.count() == 0:
		symbol = " "
		expand_it = False

	elif is_in_curr_thread_path(node) or THREAD_TREE_INFO.setdefault(node.id, "default") == "expand":
		expand_it = True
		symbol = "▼"

	# if it's been explicitly set to be collapsed, don't expand it
	elif THREAD_TREE_INFO.setdefault(node.id, "default") in ["collapse", "default"]:
		expand_it = False
		symbol = "▶"

	if node.file is None and node.name == "ROOT":
		res = "{} ROOT [{}]".format(symbol, node.id)
	else:
		res = "{}{} {} ({}:{}) [{}]".format(
			"  " * level,
			symbol,
			node.name,
			node.file.path,
			node.line,
			node.id
		)
	
	if expand_it:
		for child_node in node.children:
			res += "\n" + get_thread_node_lines(child_node, level+1)
	return res

def create_thread_node(no_parent=False):
	global THREADS

	curr_tag_name = node_name = vim.eval("expand('<cword>')")
	new_name = _input("creating thread node, name: {}. New name (return to accept)".format(node_name))
	if new_name is None:
		return
	if new_name.strip() != "":
		node_name = new_name
	
	curr_file = get_file(vim.current.buffer.name)
	curr_line,_ = vim.current.window.cursor
	#curr_tag = get_tag(curr_tag_name)
	curr_tag = None

	if no_parent:
		curr_parent = None
	else:
		curr_parent = _curr_thread()

	thread_node = PctModels.ThreadNode(
		file		= curr_file,
		line		= curr_line,
		tag			= curr_tag,
		name		= node_name,
		desc		= "",
		parent_node	= curr_parent
	)
	thread_node.save()
	_curr_thread(thread_node)

	update_thread_tree()

#----------
# Reviews
#----------

def mark_reviewed(selection=False):
	file_ = get_file()
	start_line,end_line,_,_ = get_range(visual=selection)

	reviewed = PctModels.Reviewed(
		file		= file_,
		line_start	= start_line,
		line_end	= end_line
	)
	reviewed.save()
	show_file_signs(file_)

#----------
# Notes
#----------

NOTES_NAME = "__PCT_INFO__"
had_note = False
def show_current_notes():
	global had_note
	closed_note = False

	# need to cache this since the mode may change after creating the
	# scratch buffer
	m = mode()

	line,_ = vim.current.window.cursor
	file = get_file()

	output = get_line_notes() + get_tag_notes()
	
	if len(output) > 0:
		create_scratch(
			"\n".join(output),
			fit_to_contents=False,
			return_to_orig=True,
			scratch_name=NOTES_NAME,
			wrap=False,
			syntax="pct_notes"
		)
		had_note = True
	elif buff_exists(NOTES_NAME):
		buff_goto(NOTES_NAME)
		vim.command("close")
		vim.command("wincmd p")
		had_note = False
		closed_note = True
	
	if is_visual(m) and (closed_note or had_note):
		vim.command("silent! normal! gv")

def get_line_notes():
	file = get_file()
	curr_line,curr_col = vim.current.window.cursor

	res = []
	for note in file.notes:
		if note.tag is None and note.line_start  <= curr_line <= note.line_end:
			if len(res) == 0:
				res.append("[notes from annotated lines]")
			res.append("++ lines {}-{}:\n{}\n".format(
				note.line_start,
				note.line_end,
				note.note
			))
	
	return res

def get_tag_notes():
	res = []

	tag = get_tag(create=False)
	if tag is not None:
		notes = list(tag.notes)
		if len(notes) > 0:
			res.append("[tag '{}' notes]".format(tag.name))

			for note in notes:
				res.append("++ {}:{}\n{}".format(
					rev_norm_path(note.file.path),
					note.line_start,
					"\n".join(["   {}".format(x) for x in note.note.split("\n")])
				))
	return res

def show_file_signs(file=None):
	if file is None:
		file == get_file()

	if file.reviews.count() == 0 and file.notes.count() == 0 and file.threads.count() == 0:
		return
	
	id_start = 1000
	for review in file.reviews:
		for lineno in range(review.line_start, review.line_end+1):
			show_sign(id_start, "sign_reviewed", lineno)
			id_start += 1

	for thread in file.threads:
		show_sign(id_start, "sign_thread_node", thread.line)
		id_start += 1

	for note in file.notes:
		for lineno in range(note.line_start, note.line_end+1):
			if note.tag is not None:
				continue
			switch = {
				PctModels.Note.TYPE_NOTE: "sign_note",
				PctModels.Note.TYPE_TODO: "sign_todo",
				PctModels.Note.TYPE_FINDING: "sign_finding",
			}
			show_sign(id_start, switch[note.note_type], lineno)
			id_start += 1

def add_note(path, line_start, line_end, note="", col_start=0, col_end=0, tag=None):
	"""
	"""
	file = get_file(path)
	if tag is not None and not isinstance(tag, PctModels.Tag):
		tag = get_tag(tag)

	new_note = PctModels.Note(
		file			= file,
		line_start		= line_start,
		line_end		= line_end,
		note			= note,
		col_start		= col_start,
		col_end			= col_end,
		tag				= tag,
		note_type		= PctModels.Note.TYPE_NOTE,
		thread_node		= _curr_thread()
	)
	new_note.save()

	highlight_noted_tags()
	show_current_notes()
	show_file_signs(file)

	return new_note

def save_note_from_buffer():
	line_start = int(vim.eval("b:line_start"))
	line_end = int(vim.eval("b:line_end"))
	col_start = int(vim.eval("b:col_start"))
	col_end = int(vim.eval("b:col_end"))
	bufname = vim.eval("b:note_bufname")
	tag = vim.eval("b:tag")

	with open(vim.current.buffer.name, "r") as f:
		text = f.read()

	new_note = add_note(bufname, line_start, line_end, text, col_start, col_end, tag=tag)
	retnr = int(vim.eval("b:retnr"))
	vim.command("close")
	if retnr != -1:
		vim.command("{nr}wincmd w".format(nr=retnr))

def create_note(selection=False, one_line=True):
	if not file_is_reviewable(vim.current.buffer.name):
		err("file is not reviewable/real/in-scope")
		return

	curr_thread = _curr_thread()
	if curr_thread is None:
		create_thread_node()
		curr_thread = _curr_thread()
	
	file = get_file(vim.current.buffer.name)
	line_start,line_end,col_start,col_end = get_range(visual=selection)

	print("[{},{}] - [{},{}]".format(
		line_start, col_start,
		line_end, col_end
	))

	if selection:
		tag = None
	else:
		tag = get_tag()

	if one_line:
		with v_restore_cursor():
			note_text = _input("Note")
		if note_text is None:
			return
		
		add_note(file, line_start, line_end, note_text, col_start, col_end, tag)
	else:
		name = vim.current.buffer.name
		commands = [
			"let b:new_note = 1",
			"let b:line_start = {start}".format(start=line_start),
			"let b:line_end = {end}".format(end=line_end),
			"let b:col_start = {start}".format(start=col_start),
			"let b:col_end = {end}".format(end=col_end),
			"let b:note_bufname = '{name}'".format(name=name),
			"let b:retnr = " + str(winnr())
		]
		if tag is not None:
			commands.append("let b:tag = '{}'".format(tag.name))
		else:
			commands.append("let b:tag = ''")
		note_text = multi_input("Note: ")
		vim.command(" | ".join(commands))
		vim.command("normal! $a")

def jump_to_note(down=True, curr_line=None, curr_col=1):
	"""
	Jump to the next note in the file
	"""
	if not file_is_reviewable(vim.current.buffer.name):
		return

	file_ = get_file()

	if curr_line is None:
		curr_line,curr_col = vim.current.window.cursor

	notes = file_.notes
	# searching down
	if down:
		notes = sorted(notes, key=lambda n: (n.line_start * 100000 + n.col_start))
	else:
		notes = sorted(notes, key=lambda n: (n.line_end * 100000 + n.col_end), reverse=True)
	
	dest_line = None
	dest_col = None
	for note in notes:
		start = note.line_start
		start_col = note.col_start
		end = note.line_end
		end_col = note.col_end
		if start_col == 0:
			start_col = 1
		if end_col == 0:
			end_col = 1

		if (down and start > curr_line) or (down and curr_line == start and start_col > curr_col):
			dest_line = start
			dest_col = start_col
			break
		elif (not down and end < curr_line) or (not down and end == curr_line and end_col < curr_col):
			dest_line = end
			dest_col = end_col
			break

	if dest_line is not None:
		vim.current.window.cursor = (dest_line,dest_col)
		show_current_notes()
	elif dest_line is None and len(notes) > 0:
		warn("wrapped to next note")
		if down:
			jump_to_note(down, curr_line=0)
		else:
			jump_to_note(down, curr_line=len(vim.current.buffer))

# ----------------------------------------------
# ----------------------------------------------
# ----------------------------------------------
# ----------------------------------------------
# ----------------------------------------------

def get_file(path=None, create=True, create_access=False):
	"""
	The path _should_ be a string, but in case it's an instance of a File ORM
	object, just return it.

	MAKE SURE THE PATH IS RELATIVE TO THE PROJECT ROOT!
	"""
	if isinstance(path, PctModels.File):
		return path
	if path is None:
		path = vim.current.buffer.name
	
	# normalize the path
	normd_path = norm_path(path)

	try:
		res = PctModels.File.get(PctModels.File.path == normd_path)
	except:
		if create:
			res = add_file(path)
		else:
			res = None
	
	if res is not None and create_access:
		line,_,col,_ = get_range()
		access = PctModels.FileAccess(
			file	= res,
			line	= line,
			col		= col
		)
		access.save()
	
	return res

def add_file(path):
	"""
	"""
	# TODO - need to make sure all paths are relative to the database, else
	# they won't be portable!
	path = norm_path(path)

	line_count=0
	with open(os.path.join(os.path.dirname(DB.database), path)) as f:
		data = f.read()
		line_count = data.count("\n")
		if data[-1] == "\n":
			line_count -= 1

	new_path = PctModels.File(path=path, line_count=line_count)
	new_path.save()

	update_status(vim.current.buffer.name)

	return new_path

def get_review(path, line_start, line_end, column_start=0, column_end=0, create=True):
	"""
	Get or create a review at path `path`, line, and columns. Path can be either
	an ORM object or a string
	"""
	if type(path) in [str]:
		path = get_path(path)
	
	try:
		rv = PctModels.Review
		review = PctModels.Review.get(
			rv.path			== path,
			rv.line_start	== line_start,
			rv.line_end		== line_end,
			rv.column_start	== column_start,
			rv.column_end	== column_end
		)
		return review
	except:
		if create:
			return add_review(path, line_start, line_end, column_start, column_end)
		else:
			return None

def get_reviews(path):
	"""
	Return all the reviews in the file
	"""
	path = get_path(path)
	reviews = PctModels.Review.select().where(
		PctModels.Review.path == path
	)
	return reviews

def add_review(path, line_start, line_end, column_start=0, column_end=0):
	"""
	"""
	if not file_is_reviewable(path):
		return

	path = get_path(path)
	review = PctModels.Review(
		path			= path,
		line_start		= line_start,
		line_end		= line_end,
		column_start	= column_start,
		column_end		= column_end
	)
	review.save()

	update_status(vim.current.buffer.name)

	return review

def get_notes(path):
	"""
	Get all notes in a path
	"""
	path = get_path(path)
	notes = PctModels.Note.select().where(
		PctModels.Note.path == path
	)
	return notes

def show_sign(id, sign_type, line, filename=None, buffer=None):
	if filename is None:
		filename = vim.current.buffer.name
	
	if filename is None and buf is None:
		filename = vim.current.buffer.name
	
	which = None
	if filename is not None:
		which = "file=" + filename
	elif buf is not None:
		which = "buf=" + str(buf)

	command = "sign place {id} line={line} name={sign_type} {which}".format(
		id			= id,
		line		= line,
		sign_type	= sign_type,
		which		= which
	)
	vim.command(command)

def show_review_signs(review, filename=None):
	count = 0
	for line in range(review.line_start, review.line_end+1, 1):
		id = review.id * 10000 + count
		show_sign(id, "sign_reviewed", line, filename=filename)
		count += 1

def buff_enter():
	update_status()

	# update the report every time it is looked at
	if vim.current.buffer.name is not None and os.path.basename(vim.current.buffer.name) == report_name:
		report()

def update_status(bufname=None):
	if bufname is None:
		bufname = vim.current.buffer.name
	
	try:
		if not file_is_reviewable(bufname):
			new_status = "%f"
		else:
			status = get_status(bufname, no_filename=True)
			new_status = "%f - " + status.replace("%", "%%")
			new_status = new_status.replace(" " "\\, ")

		vim.command("set statusline=" + new_status)
	except:
		pass

def unload_signs_buffer(bufname):
	command = "sign unplace *"
	vim.command(command)

def load_signs_buffer(bufname):
	if not SHOW_ANNOTATIONS:
		return

	# only worry about files that exist!
	if bufname is None or not os.path.exists(bufname):
		return
	
	unload_signs_buffer(bufname)

	path = get_path(bufname)
	reviews = get_reviews(path)
	notes = get_notes(path)

	for review in reviews:
		show_review_signs(review, filename=bufname)
	
	for note in notes:
		show_note_signs(note, filename=bufname)
	
	update_status(bufname)

def load_signs_new_buffer():
	# use this instead of `expand("%")`!!! % doens't work with BufAdd
	curr_file = vim.eval("expand('<afile>')")

	# do not add files that are outside of the current project!
	if not file_is_reviewable(curr_file):
		return

	load_signs_buffer(curr_file)

def set_initial_review_mark():
	# mark the first line in the file with the "c" mark
	vim.command('execute "normal! mc"')

def load_signs_all_buffers():
	if DB is not None:
		for buff in vim.buffers:
			load_signs_buffer(buff.name)
		vim.command("redraw!")

# ----------------------------------------
# ----------------------------------------

def create_scratch(text, fit_to_contents=True, return_to_orig=False, scratch_name="__THE_AUDIT__", retnr=-1, set_buftype=True, width=50, wrap=False, modify=False, syntax=None, window_pos="right", vertical=True):
	if buff_exists(scratch_name):
		buff_close(scratch_name, delete=True)

	if fit_to_contents:
		max_line_width = max(len(max(text.split("\n"), key=len)) + 4, 30)
	else:
		max_line_width = width
	
	orig_buffnr = winnr()
	orig_range_start = vim.current.range.start
	orig_range_end = vim.current.range.end

	if window_pos == "right":
		window_pos = "botright"
	elif window_pos == "left":
		window_pos = "topleft"
	else:
		window_pos = "botright"
	
	if vertical:
		vert = "vertical"
	else:
		vert = ""

	vim.command("silent keepalt {pos} {vert} {width}split {name}".format(
		pos=window_pos,
		width=max_line_width,
		vert=vert,
		name=scratch_name
	))
	count = 0

	buff_puts(text)

	vim.command("let b:retnr = " + str(retnr))

	# these must be done AFTER the text has been set (because of
	# the nomodifiable flag)
	if set_buftype:
		vim.command("setlocal buftype=nofile")

	vim.command("setlocal bufhidden=hide")
	vim.command("setlocal nobuflisted")
	vim.command("setlocal noswapfile")
	vim.command("setlocal noro")
	vim.command("setlocal nolist")
	vim.command("setlocal winfixwidth")
	vim.command("setlocal textwidth=0")
	vim.command("setlocal nospell")
	vim.command("setlocal norelativenumber")
	vim.command("setlocal nonumber")
	if wrap:
		vim.command("setlocal wrap")
	
	if not modify:
		vim.command("setlocal nomodifiable")
	
	if syntax is not None:
		vim.command("set syntax=" + syntax)
	
	if return_to_orig:
		vim.command("silent! wincmd p")
		#win_goto(orig_buffnr)

def multi_input(placeholder):
	tmp = tempfile.NamedTemporaryFile(delete=False)
	tmp.write(bytes(placeholder, "utf-8"))
	tmp.close()

	create_scratch(placeholder, width=80, set_buftype=False, scratch_name=tmp.name, modify=True)

def notes(search=None):
	if search is not None:
		notes = PctModels.Note.select().where(
			PctModels.Note.note % search
		)
	else:
		notes = PctModels.Note.select()
	
	lines = []
	for note in notes:
		cwd_path = rev_norm_path(note.review.path.path)

		lines.append("{path}:{line_start}\n{indented_note}".format(
			path=cwd_path,
			line_start=note.review.line_start,
			indented_note="\n".join(["    "+l for l in note.note.split("\n")])
		))
	
	text = "THE AUDIT NOTES:\n\n" + "\n".join(lines)
	create_scratch(text)

def get_status(path, no_filename=False, filename_max=0, raw=False):
	path = get_path(path)
	reviews = get_reviews(path)
	finfo = {
		"path": path,
		"reviews":[],
		"todos":0,
		"notes":0,
		"findings":0
	}

	for review in reviews:
		finfo["reviews"].append(review)
		notes = PctModels.Note.select().where(PctModels.Note.review == review)
		for note in notes:
			if "TODO" in note.note:
				finfo["todos"] += 1
			if "FINDING" in note.note:
				finfo["findings"] += 1
			else:
				finfo["notes"] += 1


	# calc percent coverage
	all_lines = set()
	for review in finfo["reviews"]:
		if review.line_start == review.line_end:
			all_lines.add(review.line_start)
		else:
			all_lines = all_lines.union(set(range(review.line_start, review.line_end)))
	if finfo["path"].line_count > 0:
		coverage = len(all_lines) / float(finfo["path"].line_count)
	else:
		coverage = 1
	
	finfo["coverage"] = coverage
	
	status_text = None

	if no_filename:
		status_text = ("%3d%%, %2d fndg, %2d todo, %2d note" % (
			finfo["coverage"] * 100,
			finfo["findings"],
			finfo["todos"],
			finfo["notes"]
		))
	else:
		status_text = (("%-" + str(filename_max) + "s - %3d%%, %2d fndg, %2d todo, %2d note") % (
			rev_norm_path(path.path),
			finfo["coverage"] * 100,
			finfo["findings"],
			finfo["todos"],
			finfo["notes"]
		))
	
	if raw:
		return {
			"text": status_text,
			"info": finfo
		}
	else:
		return status_text

def _report_info():
	statuses = []
	max_len = 0
	for path in PctModels.File.select():
		path_len = len(rev_norm_path(path.path))
		if path_len > max_len:
			max_len = path_len

	existing = {}
	for path in PctModels.File.select():
		status = get_status(path, filename_max=max_len, raw=True)

		c = status["info"]["coverage"]
		hl = None
		if c == 1.0:
			hl = "sign_audit_100_complete"
		elif c >= 0.9:
			hl = "sign_audit_good"
		elif c > 0.40:
			hl = "sign_audit_in_progress"
		else:
			hl = "sign_audit_not_much"

		statuses.append({
			"status": status["text"],
			"hl": hl
		})
		existing[path.path] = True
	
	unopened = []
	d = os.path.join(root_path(), "***")
	for root, dirnames, filenames in os.walk(root_path()):
		for filename in filenames:
			proj_file = os.path.join(root, filename)
			normd_path = norm_path(proj_file)
			if normd_path in existing or not file_is_reviewable(proj_file):
				continue
			cwd_rel_path = rev_norm_path(normd_path)
			unopened.append(cwd_rel_path)
	
	if len(unopened) > 0:
		statuses.append("")
		statuses.append("----------------")
		statuses.append("--- UNOPENED ---")
		statuses.append("----------------")
		statuses.append("")
	
	statuses += unopened

	return statuses

def toggle_annotations():
	global SHOW_ANNOTATIONS

	if SHOW_ANNOTATIONS:
		hide_annotations()
	else:
		show_annotations()

	SHOW_ANNOTATIONS = not SHOW_ANNOTATIONS

def hide_annotations():
	pass

report_name = "__THE_AUDIT_REPORT__"
def toggle_report():
	if buff_exists(report_name):
		buff_close(report_name)
		return
	report()
	
def report():
	restore = (vim.current.buffer.name is not None and os.path.basename(vim.current.buffer.name) == report_name)
	linecol, = vim.current.window.cursor

	report_info = _report_info()
	text = [
		"REPORT:",
		"",
		""
	]
	colors = []
	count = 0
	for item in report_info:
		if type(item) == str:
			text.append(item)
			continue
		
		text.append(item["status"])
		colors.append({
			"line": len(text),
			"hl": item["hl"]
		})
		count += 1

	create_scratch("\n".join(text), scratch_name=report_name)

	count = 100
	for color in colors:
		show_sign(count, color["hl"], color["line"], buffer=vim.current.buffer.number)
		count += 1

	if restore:
		vim.current.window.cursor = (linecol),

		# for some reason vim still loses the current position in the buffer
		# (if you go up/down a line, it jumps to the start of the line instead
		# of maintaining the current cursor position).
		#
		# Moving the cursor left/right seems to fix this
		vim.command("silent normal! lh")
	else:
		vim.command("normal! gg")
	
	# show the current cursor line
	vim.command("setlocal cursorline")

history_name = "__THE_AUDIT_HISTORY__"
def toggle_history_old():
	if buff_exists(history_name):
		buff_close(history_name)
		return
	
	history()

def history(n=50, match=None):
	"""
	"""
	history = []
	for review in PctModels.Review.select().order_by(PctModels.Review.timestamp.desc()).limit(n):
		showed_filename = False
		if match is None:
			history.append("{}:{} - {}".format(rev_norm_path(review.path.path), review.line_start, review.timestamp))
			showed_filename = True

		notes = PctModels.Note.select().where(PctModels.Note.review == review)
		count = 0
		for note in notes:
			if match is None or match in note.note:
				if not showed_filename:
					history.append("{}:{}".format(rev_norm_path(review.path.path), review.line_start))
					showed_filename = True
				history.append("\tNOTE ({})\n{}".format(note.timestamp, "\n".join("\t\t%s" % (x) for x in note.note.split("\n"))))
	
	if match is None:
		create_scratch("HISTORY:\n\n" + "\n".join(history), scratch_name=history_name)
	else:
		create_scratch("HISTORY MATCHING " + match + ":\n\n" + "\n".join(history), scratch_name=history_name)

	vim.command("normal! gg")

def _review_lines(filename, line_start, line_end):
	if not file_is_reviewable(vim.current.buffer.name):
		return

	with v_restore_cursor():
		review = add_review(filename, line_start, line_end)
		show_review_signs(review)
		ok("marked as reviewed")

	load_signs_buffer(vim.current.buffer.name)
	
	return review

def review_selection():
	if not file_is_reviewable(vim.current.buffer.name):
		return

	rng = vim.current.range
	# the ranges are all 0-based
	_review_lines(vim.current.buffer.name, rng.start+1, rng.end+1)

def review_current_line():
	if not file_is_reviewable(vim.current.buffer.name):
		return

	# not 0-based!
	line_, = vim.current.window.cursor
	_review_lines(vim.current.buffer.name, line, line)

def note_selection(prefix="", prompt="note", multi=False, start=None, end=None):
	if not file_is_reviewable(vim.current.buffer.name):
		return

	rng = vim.current.range

	if len(prefix) > 0:
		prefix += " "

	if multi:
		name = vim.current.buffer.name
		commands = [
			"let b:new_note = 1",
			"let b:line_start = {start}".format(start=rng.start+1),
			"let b:line_end = {end}".format(end=rng.end+1),
			"let b:note_bufname = '{name}'".format(name=name),
			"let b:retnr = " + str(winnr())
		]
		multi_input(prefix + " ")
		vim.command(" | ".join(commands))
		vim.command("startinsert!")
	else:
		with v_restore_cursor():
			note = _input(prompt)
			# the ranges are all 0-based
			new_note = add_note(vim.current.buffer.name, rng.start+1, rng.end+1, prefix + note)
			show_note_signs(new_note)
			show_current_notes()

		ok("added " + prompt)

def note_current_line(prefix="", prompt="note", multi=False, placeholder=""):
	if not file_is_reviewable(vim.current.buffer.name):
		return

	# not 0-based!
	line_, = vim.current.window.cursor
	curr_file = vim.current.buffer.name

	if len(prefix) > 0:
		prefix += " "

	if multi:
		name = vim.current.buffer.name
		commands = [
			"let b:new_note = 1",
			"let b:line_start = {start}".format(start=line),
			"let b:line_end = {end}".format(end=line),
			"let b:note_bufname = '{name}'".format(name=name),
			"let b:retnr = " + str(winnr())
		]
		multi_input(prefix + " ")
		vim.command(" | ".join(commands))
		vim.command("normal! $a")
	else:
		note = _input(prompt)
		# the cursor line number IS NOT zero based
		new_note = add_note(curr_file, line, line, prefix + note)
		show_note_signs(new_note)
		show_current_notes()

		ok("added " + prompt)

def cursor_moved():
	if DB is None:
			return
	
	if not file_is_reviewable(vim.current.buffer.name):
		return

	show_current_notes()

	if is_auditing:
		filename = vim.current.buffer.name
		line_, = vim.current.window.cursor

		reviews = get_reviews(filename)
		found_review = False
		for review in reviews:
			if review.line_start <= line and review.line_end >= line:
				found_review = True
				break
		
		if not found_review:
			review = add_review(filename, line, line)
			show_review_signs(review)

def get_notes_for_line(filename, line):
	if not file_is_reviewable(filename):
		return []
	
	try:
		all_notes = get_notes(filename)
		count = 0
		notes = []

		for note in all_notes:
			start = note.review.line_start
			end = note.review.line_end
			if start <= line and end >= line:
				notes.append(note)
	except Exception as e:
		warn("notes exist that aren't tied to a review, deleting them")
		DB.execute_sql("DELETE FROM note where review not in (SELECT id from review)")

	return notes

def note_to_text(note):
	start = note.review.line_start
	end = note.review.line_end
	if start != end:
		return "NOTE ({}-{}): {}".format(
			start,
			end,
			note.note
		)
	else:
		return "NOTE ({}): {}".format(
			start,
			note.note
		)

def get_note_text_for_line(filename, line):
	if not file_is_reviewable(filename):
		return []
	
	notes = get_notes_for_line(filename, line)
	text = []
	for note in notes:
		if len(text) > 0:
			text.append("---------------------")
		text.append(note_to_text(note))
	
	return text

had_note = False
note_scratch = "__THE_AUDIT_NOTE__"
status_line_notes = True
def show_current_notes_old(status_line_notes_override=False):
	global had_note
	global status_line_notes

	if not SHOW_ANNOTATIONS:
		return

	m = mode()

	line_, = vim.current.window.cursor
	filename = vim.current.buffer.name
	orig_bufnr = winnr()
	closed_note = False

	# only worry about files that 
	if not file_is_reviewable(filename):
		return

	text = get_note_text_for_line(filename, line)
	
	if status_line_notes and not status_line_notes_override:
		if len(text) > 0:
			status = text[0].split("\n")[0]
			# if there's more than one note, or the note is a multi-line note,
			# show some indication that there's more to be read
			if len(text) > 1:
				status += " +++"
			elif len(text[0]) > len(status):
				status += " ..."
			info(status)
		else:
			print("")
	else:
		if len(text) > 0:
			create_scratch("\n".join(text),
				fit_to_contents=False,
				return_to_orig=True,
				scratch_name=note_scratch,
				retnr=orig_bufnr,
				wrap=True
			)
			had_note = True

	if len(text) == 0 and buff_exists(note_scratch):
		buff_goto(note_scratch)
		retnr = int(vim.eval("b:retnr"))
		if retnr != -1:
			vim.command("close")
			vim.command("{nr}wincmd w".format(nr=retnr))
		#if had_note:
			#vim.command("!redraw")
		had_note = False
		closed_note = True
	
	# reselect whatever whas selected in visual mode
	if is_visual(m) and (closed_note or had_note):
		vim.command("normal! gv")

def delete_note_on_line():
	"""
	Delete the note associated with the current line
	"""

	line,_ = vim.current.window.cursor
	filename = vim.current.buffer.name
	orig_bufnr = winnr()

	if not file_is_reviewable(filename):
		return
	
	notes = get_notes_for_line(filename, line)
	if len(notes) == 0:
		return
	
	if len(notes) == 1:
		choice = _input("Are you sure you want to delete the current note? (y/n)")
		if choice[0].lower() == "y":
			notes[0].review.delete_instance()
			notes[0].delete_instance()
			ok("Deleted note")
			load_signs_buffer(vim.current.buffer.name)
	
	else:
		idx = 0
		for note in notes:
			text = note_to_text(note)
			warn("  %s - %s" % (idx, text.split("\n")[0]))
			idx += 1
		choice = _input("Which note would you like to delete? (0-%d)" % (len(notes)-1))
		print("")

		try:
			choice = int(choice)
		except:
			err("Invalid choice")
			return

		if not (0 <= choice <= len(notes)):
			err("Invalid choice")
			return

		notes[choice].review.delete_instance()
		notes[choice].delete_instance()
		print("")
		ok("Deleted note")
		load_signs_buffer(vim.current.buffer.name)

def edit_note_on_line():
	"""
	Delete the note associated with the current line
	"""
	return
	# this is not ready yet

	line,_ = vim.current.window.cursor
	filename = vim.current.buffer.name
	orig_bufnr = winnr()

	if not file_is_reviewable(filename):
		return
	
	notes = get_notes_for_line(filename, line)
	if len(notes) == 0:
		return
	
	if len(notes) == 1:
		note = notes[0]
		note_text = note.note
		note.delete_instance()

		start = note.review.line_start
		end = note.review.line_end
	else:
		idx = 0
		for note in notes:
			text = note_to_text(note)
			warn("  %s - %s" % (idx, text.split("\n")[0]))
			idx += 1
		choice = _input("Which note would you like to delete? (0-%d)" % (len(notes)-1))
		print("")

		try:
			choice = int(choice)
		except:
			err("Invalid choice")
			return

		if not (0 <= choice <= len(notes)):
			err("Invalid choice")
			return

		notes[choice].delete_instance()
		print("")
		ok("Deleted note")
		load_signs_buffer(vim.current.buffer.name)

def jump_to_note_old(direction=1, curr_line=None):
	"""
	Jump to the next note in the file
	"""
	notes = get_notes(vim.current.buffer.name)

	down = direction == 1

	# searching down
	if down:
		notes = sorted(notes, key=lambda n: n.review.line_start)
	else:
		notes = sorted(notes, key=lambda n: n.review.line_end, reverse=True)

	if curr_line is None:
		curr_line,_ = vim.current.window.cursor
	
	dest_line = None
	for note in notes:
		start = note.review.line_start
		end = note.review.line_end
		if down and start > curr_line:
			dest_line = start
			break
		elif not down and end < curr_line:
			dest_line = end
			break
	
	if dest_line is not None:
		vim.current.window.cursor = (dest_line,0)
		show_current_notes()
	elif dest_line is None and len(notes) > 0:
		warn("wrapped to next note")
		if down:
			jump_to_note(direction=direction, curr_line=0)
		else:
			jump_to_note(direction=direction, curr_line=len(vim.current.buffer))

is_auditing = False
def toggle_audit():
	global is_auditing
	is_auditing = not is_auditing

	if is_auditing:
		vim.command("hi StatusLine cterm=bold ctermfg=black ctermbg=red")
	else:
		vim.command("hi StatusLine cterm=bold ctermfg=blue ctermbg=white")
EOF
endfunction
call DefinePct()

function! DefineAutoCommands()
	augroup Pct!
		autocmd!
		"autocmd BufReadPre * py3 set_initial_review_mark()
		autocmd BufAdd * py3 process_new_buffer()
		autocmd VimEnter * py3 process_new_buffer()
		autocmd BufEnter * py3 process_buff_enter()
		autocmd CursorMoved * py3 process_cursor_moved()
		autocmd BufWritePost * call MaybeSaveNote()
		"autocmd VimEnter * py3 load_signs_all_buffers()
		"autocmd CursorMoved * py3 cursor_moved()
	augroup END
endfunction

py3 init_db(create=False)

" ---------------------------------------------
" ---------------------------------------------

" --------
" THREADS
" --------
nmap [t :PctThreadCreate<CR>
nmap [T :py3 toggle_thread_tree()<CR>

" --------
" NOTES
" --------
vmap [a :py3 create_note(selection=True)<CR>
vmap [A :py3 create_note(selection=True, one_line=False)<CR>
nmap [a :py3 create_note()<CR>
nmap [A :py3 create_note(one_line=False)<CR>

" open the filepath under the cursor in a new tab
map [o <C-w>gF:setlocal ro<CR>:setlocal nomodifiable<CR>:setlocal ro<CR>

" Notes/etc navigation
map <silent> [n :py3 jump_to_note()<CR>
map <silent> [N :py3 jump_to_note(down=False)<CR>

" Reviews
nmap [r :py3 mark_reviewed()<CR> 
vmap [r :py3 mark_reviewed(selection=True)<CR> 

" History/Reporting
map [h :py3 toggle_history()<CR>
 
" " mark from last mark up the cursor as reviewed
" nmap [u mx'cV`x[rmc
" 
" " annotate the selected lines
" vmap [a :py3 note_selection()<CR> 
" nmap [a :py3 note_current_line()<CR>
" vmap [A :py3 note_selection(multi=True)<CR> 
" nmap [A :py3 note_current_line(multi=True)<CR>
" 
" " add a finding for the selected lines
" vmap [f :py3 note_selection(prefix="FINDING", prompt="finding")<CR> 
" nmap [f :py3 note_current_line(prefix="FINDING", prompt="finding")<CR>
" vmap [F :py3 note_selection(prefix="FINDING", prompt="finding", multi=True)<CR> 
" nmap [F :py3 note_current_line(prefix="FINDING", prompt="finding", multi=True)<CR>
" 
" nmap [d :py3 delete_note_on_line()<CR>
" nmap [e :py3 edit_note_on_line()<CR>
" 
" " add a todo for the selected lines
" vmap [t :py3 note_selection(prefix="TODO", prompt="todo")<CR> 
" nmap [t :py3 note_current_line(prefix="TODO", prompt="todo")<CR>
" vmap [T :py3 note_selection(prefix="TODO", prompt="todo", multi=True)<CR> 
" nmap [T :py3 note_current_line(prefix="TODO", prompt="todo", multi=True)<CR>
" 
" " toggle auditing (q like record)
" " NOTE - not really recommended, is more of an experiment
" " map [q :py3 toggle_audit()<CR>
" 
" nmap [H :py3 toggle_annotations()<CR>
" 
" " show the current report
" nmap [R :py3 toggle_report()<CR>
" 
" " show all notes containing the current line
" " this should not be needed, as the current line's notes are automatically
" " displayed
" map [? :py3 show_current_notes(status_line_notes_override=True)<CR>
" 
" " show a recent history
" map [h :py3 toggle_history()<CR>
" 
" 
" " jump to the previous note

command! -nargs=0 PctThreadCreate py3 create_thread_node()
command! -nargs=0 PctInit py3 init_db(True)

" command! -nargs=0 PctReport py3 report()
" command! -nargs=0 PctNotes py3 notes()
" command! -nargs=0 PctAudit py3 toggle_audit()

" always show the status of files
set laststatus=2

function! DefineHighlights()
	highlight tag_is_noted cterm=underline,bold
	highlight current_thread cterm=underline,bold ctermbg=red ctermfg=white

	highlight hl_finding ctermfg=red ctermbg=black
	highlight hl_annotated_line ctermbg=black
	highlight hl_todo ctermfg=yellow ctermbg=black
	highlight hl_note ctermfg=green ctermbg=black
	highlight hl_reviewed ctermfg=blue ctermbg=black

	sign define sign_reviewed text=RR texthl=hl_reviewed
	sign define sign_finding text=!! texthl=hl_finding linehl=hl_annotated_line
	sign define sign_todo text=?? texthl=hl_todo linehl=hl_annotated_line
	sign define sign_note text=>> texthl=hl_note
	sign define sign_thread_node text=T texthl=hl_todo

	highlight hl_audit_100_complete ctermfg=green
	highlight hl_audit_good ctermfg=green
	highlight hl_audit_in_progress ctermfg=yellow
	highlight hl_audit_not_much ctermfg=red
	highlight hl_audit_out_of_scope ctermfg=blue

	sign define sign_audit_100_complete text=✓ linehl=hl_audit_100_complete texthl=hl_note
	sign define sign_audit_good text=++ linehl=hl_audit_good texthl=hl_note
	sign define sign_audit_in_progress text=+ linehl=hl_audit_in_progress texthl=hl_audit_in_progress
	sign define sign_audit_not_much text=. linehl=hl_audit_not_much texthl=hl_audit_not_much
	sign define sign_audit_out_of_scope text=X linehl=hl_audit_out_of_scope texthl=hl_audit_out_of_scope
endfunction
call DefineHighlights()

function! MaybeSaveNote()
	if exists("b:new_note")
		py3 save_note_from_buffer()
	endif
endfunction
