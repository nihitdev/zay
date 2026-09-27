// Arch's package library supplies database and version semantics; no transactions
// or database updates are initiated by the planner.
pub const c = @cImport({
    @cInclude("alpm.h");
    @cInclude("stdlib.h");
    @cInclude("fnmatch.h");
});
