# Agent Instructions

- Commit each completed change.
- Update package versions according to OpenWrt release/versioning rules.
- Do not build the project.
- Do not run or write tests.
- Clean up obsolete or dead code caused by changes.
- Use native LuCI UI components whenever possible.
- Follow OpenWrt best practices.
- Use LF line endings for all files.
- Keep large GeoIP/nftables set population split across explicit `add element` batches; never collapse it into one huge `elements = { ... }` block or single `add element` command because Netlink size limits can truncate or fail large sets.
