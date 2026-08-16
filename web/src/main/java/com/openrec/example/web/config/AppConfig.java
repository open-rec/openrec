package com.openrec.example.web.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import com.openrec.client.RecClient;

@Configuration
public class AppConfig {

    @Value("${rec.server.endpoint}")
    private String recServerEndpoint;

    /**
     * Recommend and push both go through the sdk rather than hand-rolled HTTP, which is the point
     * of this demo. One instance is enough: it wraps a thread-safe OkHttpClient.
     */
    @Bean
    public RecClient recClient() {
        return new RecClient(recServerEndpoint);
    }
}
