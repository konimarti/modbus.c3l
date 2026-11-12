module bump_version;

import std::io;
import std::io::file;

// Sets the version of the library: "version" in project.json and the VERSION constant in modbus.c3.
//
//     c3c compile-run tools/bump_version.c3 -- 0.2.0        (from the repository root)
//
// Exit 1 and nothing written unless the argument is MAJOR.MINOR.PATCH and each pattern occurs exactly once.
// An optional second argument names another root directory (used to test the tool on a copy).

const String PROJECT_FILE = "project.json";
const String MODULE_FILE = "modbus.c3";
const String PROJECT_KEY = "\"version\": \"";
const String MODULE_KEY = "const String VERSION = \"";

fn bool is_number(String s)
{
	if (s.len == 0) return false;
	foreach (c : s)
	{
		if (c < '0' || c > '9') return false;
	}
	return true;
}

fn bool is_semver(String s)
{
	String[] parts = s.tsplit(".");
	if (parts.len != 3) return false;
	foreach (p : parts)
	{
		if (!is_number(p)) return false;
	}
	return true;
}

// Index of the single occurrence of key in text, or -1 when there is none or more than one.
fn sz find_once(String text, String key)
{
	sz at = -1;
	for (usz i = 0; i + key.len <= text.len; i++)
	{
		if (text[i:key.len] != key) continue;
		if (at >= 0) return -1;
		at = (sz)i;
	}
	return at;
}

// The text with the quoted value after `key` replaced; the replaced line goes to *line.
fn String? replace_version(String text, String key, String version, String* line)
{
	sz at = find_once(text, key);
	if (at < 0) return NOT_FOUND~;
	usz start = (usz)at + key.len;
	usz end = start;
	while (end < text.len && text[end] != '"') end++;
	if (end >= text.len) return NOT_FOUND~;
	String result = string::tformat("%s%s%s", text[:start], version, text[end..]);
	usz line_start = (usz)at;
	while (line_start > 0 && text[line_start - 1] != '\n') line_start--;
	usz line_end = start + version.len;
	while (line_end < result.len && result[line_end] != '\n') line_end++;
	*line = result[line_start:line_end - line_start];
	return result;
}

fn int main(String[] args)
{
	@pool()
	{
		if (args.len < 2 || args.len > 3 || !is_semver(args[1]))
		{
			io::eprintn("usage: c3c compile-run tools/bump_version.c3 -- MAJOR.MINOR.PATCH [ROOT]");
			return 1;
		}
		String version = args[1];
		String root = args.len == 3 ? args[2] : ".";
		String project_path = string::tformat("%s/%s", root, PROJECT_FILE);
		String module_path = string::tformat("%s/%s", root, MODULE_FILE);
		String? project = (String)file::load_temp(project_path);
		String? module_text = (String)file::load_temp(module_path);
		if (catch f1 = project)
		{
			io::eprintfn("cannot read %s", project_path);
			return 1;
		}
		if (catch f2 = module_text)
		{
			io::eprintfn("cannot read %s", module_path);
			return 1;
		}
		String project_line;
		String module_line;
		String? new_project = replace_version(project, PROJECT_KEY, version, &project_line);
		String? new_module = replace_version(module_text, MODULE_KEY, version, &module_line);
		if (catch f3 = new_project)
		{
			io::eprintfn("%s: expected exactly one %s...", project_path, PROJECT_KEY);
			return 1;
		}
		if (catch f4 = new_module)
		{
			io::eprintfn("%s: expected exactly one %s...", module_path, MODULE_KEY);
			return 1;
		}
		// both patterns are fine: now write
		if (catch f5 = file::save(project_path, new_project))
		{
			io::eprintfn("cannot write %s", project_path);
			return 1;
		}
		if (catch f6 = file::save(module_path, new_module))
		{
			io::eprintfn("cannot write %s", module_path);
			return 1;
		}
		io::printfn("%s: %s", project_path, project_line.trim());
		io::printfn("%s: %s", module_path, module_line.trim());
		return 0;
	};
}
