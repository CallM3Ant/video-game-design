#!/usr/bin/env python

env = SConscript("godot-cpp/SConstruct")

env.Append(CPPPATH=["src/"])
env.VariantDir("build", "src", duplicate=0)
sources = Glob("build/*.cpp")

library = env.SharedLibrary(
    "bin/terrain_generator{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)

env.NoCache(library)
Default(library)
