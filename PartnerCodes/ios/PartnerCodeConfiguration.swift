import Foundation

/// Configuration for connecting to the Supabase partner code backend.
///
/// Set these values in your app's initialization before using `PartnerCodeManager`.
///
/// Example:
/// ```swift
/// PartnerCodeConfiguration.shared = PartnerCodeConfiguration(
///     supabaseURL: URL(string: "https://your-project.supabase.co")!,
///     supabaseAnonKey: "your-anon-key"
/// )
/// ```
public struct PartnerCodeConfiguration {

    /// Shared configuration instance. Must be set before using `PartnerCodeManager`.
    public static var shared: PartnerCodeConfiguration?

    /// The Supabase project URL (e.g., "https://your-project.supabase.co")
    public let supabaseURL: URL

    /// The Supabase anonymous/public API key
    public let supabaseAnonKey: String

    /// Base URL for Edge Functions (defaults to supabaseURL + "/functions/v1")
    public var functionsBaseURL: URL {
        supabaseURL.appendingPathComponent("functions").appendingPathComponent("v1")
    }

    public init(supabaseURL: URL, supabaseAnonKey: String) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }
}
