const std = @import("std");
const strings_mod = @import("strings.zig");
const Locale = strings_mod.Locale;
const Strings = strings_mod.Strings;
const getStrings = strings_mod.getStrings;
const localeFromEnvlang = strings_mod.localeFromEnvlang;

pub const I18nManager = struct {
    locale: Locale,
    strings: Strings,

    pub fn init(locale: Locale) I18nManager {
        return .{
            .locale = locale,
            .strings = getStrings(locale),
        };
    }

    pub fn initWithLocaleName(locale_name: []const u8) I18nManager {
        const locale = localeFromName(locale_name);
        return init(locale);
    }

    pub fn deinit(self: *I18nManager) void {
        _ = self;
    }

    pub fn setLocale(self: *I18nManager, locale: Locale) void {
        self.locale = locale;
        self.strings = getStrings(locale);
    }

    /// Set the locale from a friendly name ("en", "ja", "zh", "pt", ...).
    /// Falls back to English for unknown names.
    pub fn setLocaleByName(self: *I18nManager, name: []const u8) void {
        self.setLocale(localeFromName(name));
    }

    pub fn detectLocale(self: *I18nManager, env_map: *const std.process.Environ.Map) void {
        if (env_map.get("LANG")) |lang| {
            self.locale = localeFromEnvlang(lang);
        } else if (env_map.get("LC_ALL")) |lang| {
            self.locale = localeFromEnvlang(lang);
        } else if (env_map.get("LC_MESSAGES")) |lang| {
            self.locale = localeFromEnvlang(lang);
        } else {
            self.locale = .en;
        }
        self.strings = getStrings(self.locale);
    }

    pub fn t(self: *const I18nManager) Strings {
        return self.strings;
    }

    pub fn localeName(self: *const I18nManager) []const u8 {
        return switch (self.locale) {
            .en => "English",
            .ja => "日本語",
            .zh_Hans => "简体中文",
            .pt_BR => "Português (Brasil)",
        };
    }
};

fn localeFromName(name: []const u8) Locale {
    if (std.ascii.eqlIgnoreCase(name, "en") or std.ascii.eqlIgnoreCase(name, "english")) return .en;
    if (std.ascii.eqlIgnoreCase(name, "ja") or std.ascii.eqlIgnoreCase(name, "japanese") or std.mem.eql(u8, name, "日本語")) return .ja;
    if (std.ascii.eqlIgnoreCase(name, "zh") or std.ascii.eqlIgnoreCase(name, "zh-hans") or std.ascii.eqlIgnoreCase(name, "zh_hans") or std.ascii.eqlIgnoreCase(name, "chinese") or std.mem.eql(u8, name, "简体中文")) return .zh_Hans;
    if (std.ascii.eqlIgnoreCase(name, "pt") or std.ascii.eqlIgnoreCase(name, "pt-br") or std.ascii.eqlIgnoreCase(name, "pt_br") or std.ascii.eqlIgnoreCase(name, "portuguese") or std.mem.eql(u8, name, "português")) return .pt_BR;
    return .en;
}

test "i18n init" {
    var mgr = I18nManager.init(.en);
    defer mgr.deinit();
    try std.testing.expectEqualStrings("Ready", mgr.strings.status_ready);
}

test "i18n set locale" {
    var mgr = I18nManager.init(.en);
    defer mgr.deinit();
    mgr.setLocale(.ja);
    try std.testing.expectEqualStrings("準備完了", mgr.strings.status_ready);
}

test "i18n locale name" {
    var mgr = I18nManager.init(.en);
    defer mgr.deinit();
    try std.testing.expectEqualStrings("English", mgr.localeName());
    mgr.setLocale(.ja);
    try std.testing.expectEqualStrings("日本語", mgr.localeName());
}

test "i18n set locale by name" {
    var mgr = I18nManager.init(.en);
    defer mgr.deinit();
    mgr.setLocaleByName("zh");
    try std.testing.expectEqualStrings("简体中文", mgr.localeName());
    mgr.setLocaleByName("pt-BR");
    try std.testing.expectEqualStrings("Português (Brasil)", mgr.localeName());
    mgr.setLocaleByName("bogus");
    try std.testing.expectEqualStrings("English", mgr.localeName());
}

test "locale from name" {
    try std.testing.expect(localeFromName("en") == .en);
    try std.testing.expect(localeFromName("ja") == .ja);
    try std.testing.expect(localeFromName("zh_Hans") == .zh_Hans);
    try std.testing.expect(localeFromName("pt_BR") == .pt_BR);
    try std.testing.expect(localeFromName("unknown") == .en);
}
