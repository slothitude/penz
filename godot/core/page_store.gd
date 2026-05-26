extends RefCounted
## Page CRUD — manages saved pages in user://pages/

const PAGES_DIR := "user://pages/"


func list_pages() -> PackedStringArray:
	if not DirAccess.dir_exists_absolute(PAGES_DIR):
		return []
	var files: PackedStringArray = []
	var dir := DirAccess.open(PAGES_DIR)
	if dir:
		dir.list_dir_begin()
		var fn := dir.get_next()
		while fn != "":
			if fn.ends_with(".svg"):
				files.append(PAGES_DIR + fn)
			fn = dir.get_next()
		dir.list_dir_end()
	files.sort()
	# Newest first
	files.reverse()
	return files


func delete_page(path: String) -> bool:
	return DirAccess.remove_absolute(path) == OK


func page_name(path: String) -> String:
	return path.get_file().replace(".svg", "").replace("page_", "").replace("_", " ")


func page_exists(path: String) -> bool:
	return FileAccess.file_exists(path)
