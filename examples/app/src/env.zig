const env = @import("env_config");

pub const variables = env.define(.{
    .GREETING_PREFIX = env.private(.string, .{ .default = "Hello" }),
    .PUBLIC_SITE_NAME = env.public(.string, .{ .default = "Yaan" }),
    .PUBLIC_DEBUG = env.public(.bool, .{ .default = false, .static = true }),
});
