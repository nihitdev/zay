const std = @import("std");

/// User-facing translations belong at the command boundary; internal errors stay typed.
pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "not enough memory; close other applications and retry",
        error.AccessDenied => "permission denied; check file permissions",
        error.FileNotFound => "required file or executable was not found",
        error.MalformedPacmanOutput => "could not read pacman output; check that pacman works directly",
        error.StreamTooLong => "pacman output is too large; narrow the query",
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
