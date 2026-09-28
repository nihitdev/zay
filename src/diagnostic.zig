const std = @import("std");

/// User-facing translations belong at the command boundary; internal errors stay typed.
pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "not enough memory; close other applications and retry",
        error.AccessDenied => "permission denied; check file permissions",
        error.FileNotFound => "required file or executable was not found",
        error.MalformedPacmanOutput => "could not read pacman output; check that pacman works directly",
        error.StreamTooLong => "pacman output is too large; narrow the query",
        error.RefusingRootBuild => "refusing to run an AUR build as root",
        error.UnsafeCachePath, error.UnsafeReviewState => "cache or review state has unsafe ownership or permissions",
        error.GitFailed => "Git operation failed; check the AUR connection and cached repository",
        error.OriginMismatch => "cached AUR repository has an unexpected origin; inspect it before retrying",
        error.WorkingTreeModified => "cached AUR repository has local changes; inspect it before retrying",
        error.DestinationCollision => "cache path exists with an unexpected type; inspect it before retrying",
        error.ArchiveFailed => "could not prepare the pinned AUR source tree",
        error.ReviewFileMismatch, error.BuildRevisionMismatch => "prepared build files differ from the reviewed revision; refusing to execute them",
        error.MakepkgFailed => "makepkg failed; review its output above",
        error.NoArtifacts => "makepkg produced no package files in the build directory",
        error.ArtifactOutsideBuildDirectory, error.InvalidArtifact => "makepkg returned an invalid package artifact path",
        error.InvalidPackageArtifact => "pacman could not read a built package file",
        error.PackageOutputMismatch, error.PackageVersionMismatch => "built package names or versions do not match .SRCINFO",
        error.SrcinfoMissing => ".SRCINFO is missing from the fetched AUR revision",
        error.MetadataMismatch, error.MetadataVersionMismatch => "AUR RPC metadata does not match the fetched .SRCINFO; retry the plan",
        error.PackageBaseMismatch, error.PackageMissingFromSrcinfo => "selected AUR package is missing from its package base metadata",
        error.WriteFailed, error.BrokenPipe => "could not write output; check the destination",
        error.ReadFailed => "could not read input; retry the operation",
        error.Canceled => "operation canceled",
        else => "operation failed; retry and report the command if the problem persists",
    };
}

pub fn aurMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "connection refused; check your network and proxy settings",
        error.ConnectionResetByPeer, error.ConnectionTimedOut, error.Timeout, error.EndOfStream, error.ReadFailed, error.WriteFailed => "connection interrupted; check your network and retry",
        error.NetworkUnreachable, error.HostUnreachable => "network unreachable; check your connection",
        error.UnknownHostName, error.TemporaryNameServerFailure, error.NameServerFailure => "could not resolve server name; check DNS and proxy settings",
        error.TlsInitializationFailed, error.TlsCertificateNotVerified, error.CertificateExpired, error.CertificateNotYetValid, error.CertificateIssuerNotFound => "could not verify secure connection; check system time and CA certificates",
        error.ResponseTooLarge, error.StreamTooLong => "response is too large; narrow the query",
        error.RequestTooLarge => "request is too large; use a shorter query or fewer package names",
        error.SyntaxError, error.UnexpectedToken, error.InvalidCharacter, error.MissingField, error.DuplicateField, error.MalformedRpcResponse, error.UnsupportedRpcVersion, error.UnsupportedContentEncoding => "invalid server response; retry later",
        error.OutOfMemory, error.Canceled => message(err),
        else => "request failed; check your connection and retry",
    };
}

test "diagnostics explain recovery without exposing internal error names" {
    try std.testing.expectEqualStrings("connection refused; check your network and proxy settings", aurMessage(error.ConnectionRefused));
    try std.testing.expectEqualStrings("invalid server response; retry later", aurMessage(error.SyntaxError));
    try std.testing.expectEqualStrings("could not read pacman output; check that pacman works directly", message(error.MalformedPacmanOutput));
    try std.testing.expect(std.mem.indexOf(u8, message(error.SomeInternalDetail), "SomeInternalDetail") == null);
}
