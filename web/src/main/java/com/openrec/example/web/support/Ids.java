package com.openrec.example.web.support;

public final class Ids {

    private Ids() {}

    /**
     * Strip the quotes off an item id.
     * <p>
     * Two places hand us quoted ids. {@code InitStandalone} writes recall tables with
     * {@code GenericJackson2JsonRedisSerializer}, so a sorted-set member is literally
     * {@code "item_1069"} — quotes included. And rec-server's multi-key
     * {@code RedisService.getZSet(List, ...)} does not unquote its members, so ids coming back from
     * the i2i channel keep them too (the single-key overload does strip them).
     * <p>
     * Left unstripped, {@code item:{"item_1069"}} misses in Redis and the card renders empty.
     */
    public static String unquote(String raw) {
        if (raw == null) {
            return null;
        }
        return raw.replaceAll("^\"|\"$", "");
    }
}
