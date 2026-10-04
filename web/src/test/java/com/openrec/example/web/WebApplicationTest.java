package com.openrec.example.web;

import static org.assertj.core.api.Assertions.assertThat;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Arrays;
import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import static org.mockito.Mockito.when;

import com.openrec.example.web.model.ItemView;
import com.openrec.example.web.model.ScoredId;
import com.openrec.example.web.service.ItemService;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class WebApplicationTest {
    @LocalServerPort private int port;
    @Autowired private ItemService items;
    @MockitoBean private StringRedisTemplate redis;
    @MockitoBean private ValueOperations<String, String> values;

    @Test void servesDefaultsAndUncachedAssets() throws Exception {
        HttpClient client = HttpClient.newHttpClient();
        HttpResponse<String> response = client.send(HttpRequest.newBuilder(
            URI.create("http://127.0.0.1:" + port + "/api/config")).build(),
            HttpResponse.BodyHandlers.ofString());
        assertThat(response.statusCode()).isEqualTo(200);
        JsonNode config = JsonMapper.builder().build().readTree(response.body());
        assertThat(config.get("userId").asString()).isEqualTo("user_0");
        assertThat(config.get("pageSize").asInt()).isEqualTo(12);
        assertThat(response.body()).doesNotContain("serving-graph-token");
        HttpResponse<String> page = client.send(HttpRequest.newBuilder(
            URI.create("http://127.0.0.1:" + port + "/index.html")).build(),
            HttpResponse.BodyHandlers.ofString());
        assertThat(page.statusCode()).isEqualTo(200);
        assertThat(page.headers().firstValue("cache-control").orElse("")).contains("no-store");
    }

    @Test void readsExistingRedisJsonAndPreservesMissingItemOrder() {
        when(redis.opsForValue()).thenReturn(values);
        when(values.multiGet(Arrays.asList("item:{one}", "item:{missing}"))).thenReturn(Arrays.asList(
            "{\"id\":\"one\",\"title\":\"old item\",\"status\":1,\"futureField\":true}", null));
        ScoredId first = new ScoredId("one", 2d);
        ScoredId second = new ScoredId("missing", 1d);
        List<ItemView> result = items.resolve(Arrays.asList(first, second));
        assertThat(result).hasSize(2);
        assertThat(result.get(0).getTitle()).isEqualTo("old item");
        assertThat(result.get(0).isResolved()).isTrue();
        assertThat(result.get(1).getId()).isEqualTo("missing");
        assertThat(result.get(1).isResolved()).isFalse();
    }
}
