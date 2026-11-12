module modbus::version_test;

import std::core::env;
import modbus;

// In the library's own test build the library is the top-level project, so env::PROJECT_VERSION is the
// "version" of this project.json.
fn void version_matches_project_json() @test
{
	assert(modbus::VERSION == env::PROJECT_VERSION, "modbus::VERSION %s, project.json %s", modbus::VERSION, env::PROJECT_VERSION);
}
