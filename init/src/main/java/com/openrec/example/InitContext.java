package com.openrec.example;

import co.elastic.clients.elasticsearch.ElasticsearchClient;
import com.openrec.example.util.EsUtil;
import com.openrec.example.util.RedisUtil;
import org.springframework.data.redis.connection.jedis.JedisConnectionFactory;
import org.springframework.data.redis.core.RedisTemplate;
import java.io.IOException;
import java.nio.file.Path;

/** Owns one initialization's paths and lazily created storage clients. */
public final class InitContext implements AutoCloseable {
    private final InitOptions options;
    private RedisTemplate redis;
    private ElasticsearchClient elasticsearch;

    public InitContext(InitOptions options) {
        this.options = options;
    }

    public Path data(String relativePath) {
        return options.dataDir().resolve(relativePath);
    }

    public Path model(String relativePath) {
        return options.modelDir().resolve(relativePath);
    }

    public RedisTemplate redis() {
        if (redis == null) {
            redis = RedisUtil.getRedis(options.redisHost(), options.redisPort());
            if (redis == null) {
                throw new IllegalStateException("Redis client creation failed");
            }
        }
        return redis;
    }

    public ElasticsearchClient elasticsearch() {
        if (elasticsearch == null) {
            elasticsearch = EsUtil.getEs(options.esHost(), options.esPort(),
                    options.esUser(), options.esPassword());
            if (elasticsearch == null) {
                throw new IllegalStateException("Elasticsearch client creation failed");
            }
        }
        return elasticsearch;
    }

    @Override
    public void close() throws IOException {
        try {
            if (elasticsearch != null) {
                elasticsearch._transport().close();
            }
        } finally {
            if (redis != null && redis.getConnectionFactory() instanceof JedisConnectionFactory factory) {
                factory.destroy();
            }
        }
    }
}
