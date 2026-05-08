module quickbite.dmd_util;

private:

public ref auto moduleMembers(
    imported!"dmd.dmodule".Module module_,
) @trusted pure {
    return *module_.members;
}
