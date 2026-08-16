package com.openrec.example.util;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.commons.lang3.tuple.Pair;
import org.springframework.data.redis.connection.jedis.JedisConnectionFactory;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.serializer.GenericJackson2JsonRedisSerializer;
import org.springframework.data.redis.serializer.StringRedisSerializer;

import java.util.HashMap;
import java.util.Map;

public class RedisUtil {

    private static Map<Pair<String, Integer>, RedisTemplate> redisMap;

    static {
        redisMap = new HashMap<>();
    }

    public static RedisTemplate getRedis(String host, int port) {
        Pair<String, Integer> key = Pair.of(host, port);
        if (!redisMap.containsKey(key)) {
            JedisConnectionFactory jedisConnectionFactory = new JedisConnectionFactory();
            jedisConnectionFactory.setHostName(host);
            jedisConnectionFactory.setPort(port);
            RedisTemplate redisTemplate = new RedisTemplate();
            redisTemplate.setConnectionFactory(jedisConnectionFactory);
            redisTemplate.afterPropertiesSet();
            redisTemplate.setKeySerializer(new StringRedisSerializer());
            redisTemplate.setValueSerializer(new GenericJackson2JsonRedisSerializer(new ObjectMapper()));
            redisMap.put(key, redisTemplate);
        }
        return redisMap.get(key);
    }
}
