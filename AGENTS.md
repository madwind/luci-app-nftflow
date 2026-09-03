# Agent Instructions

- Commit each completed change.
- Update package versions according to OpenWrt release/versioning rules.
- Do not build the project.
- Do not run or write tests.
- Clean up obsolete or dead code caused by changes.
- Use native LuCI UI components whenever possible.
- Follow OpenWrt best practices.
- Use LF line endings for all files.
- Load GeoIP sets with separate `nft` invocations of at most 256 elements each; never combine batches in one `nft -f` call.
