package com.openrec.example;

import co.elastic.clients.elasticsearch.ElasticsearchClient;
import com.openrec.example.util.EsUtil;
import com.openrec.example.util.JsonUtil;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVPrinter;
import org.junit.Test;
import com.openrec.example.task.LanguageEmbeddingTask;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.Assert.*;
import static org.junit.Assume.assumeTrue;

/** Opt-in Elasticsearch acceptance; imports only generated, uniquely scoped test data. */
public class LanguageEmbeddingIntegrationTest {
    @Test
    public void importsAndAtomicallyReplacesLanguageVectors() throws Exception {
        String fixture = System.getenv("EMBEDDING_LIVE_FIXTURE");
        assumeTrue("requires local Elasticsearch and the live vector fixture", fixture != null);
        List<Map<String, Object>> documents = JsonUtil.jsonToObj(Files.readString(Path.of(fixture)), List.class);
        String scene = "openrec-language-init-it-" + UUID.randomUUID();
        String alias = scene + "-query-title-emb-index";
        String scheduled = "openrec-title-scheduled-it-" + UUID.randomUUID();
        Path input = Files.createTempFile("openrec-language-init-", ".csv");
        ElasticsearchClient es = EsUtil.getEs("127.0.0.1", 9200, "elastic",
            System.getenv().getOrDefault("ELASTIC_PASSWORD", "openrec-es-password"));
        try {
            try (CSVPrinter printer = new CSVPrinter(Files.newBufferedWriter(input),
                    CSVFormat.DEFAULT.withHeader("scene", "item", "vector"))) {
                for (Map<String, Object> document : documents) {
                    printer.printRecord(scene, document.get("id"), JsonUtil.objToJson(document.get("vector")));
                    printer.printRecord("another-scene", document.get("id"), JsonUtil.objToJson(document.get("vector")));
                }
            }
            LanguageEmbeddingTask.load(es, input.toString(), alias);
            assertEquals(documents.size(), es.count(c -> c.index(alias)).count());
            String first = es.indices().getAlias(a -> a.name(alias)).result().keySet().iterator().next();
            // Scheduled publication uses a different physical prefix from bootstrap.
            es.indices().create(i -> i.index(scheduled));
            es.indices().updateAliases(a -> a
                .actions(action -> action.remove(r -> r.index(first).alias(alias)))
                .actions(action -> action.add(add -> add.index(scheduled).alias(alias))));
            LanguageEmbeddingTask.load(es, input.toString(), alias);
            assertEquals(1, es.indices().getAlias(a -> a.name(alias)).result().size());
            String second = es.indices().getAlias(a -> a.name(alias)).result().keySet().iterator().next();
            assertNotEquals(first, second);
            assertEquals(documents.size(), es.count(c -> c.index(alias)).count());
            try (CSVPrinter printer = new CSVPrinter(Files.newBufferedWriter(input),
                    CSVFormat.DEFAULT.withHeader("scene", "item", "vector"))) {
                Object id = documents.get(0).get("id");
                List<Double> vector = (List<Double>) documents.get(0).get("vector");
                printer.printRecord("first", id, JsonUtil.objToJson(vector));
                printer.printRecord("second", id, JsonUtil.objToJson(
                    vector.stream().map(value -> -value).collect(java.util.stream.Collectors.toList())));
            }
            try {
                LanguageEmbeddingTask.load(es, input.toString(), alias);
                fail("conflicting item vectors must fail before activation");
            } catch (IllegalArgumentException expected) {
                assertEquals(second, es.indices().getAlias(a -> a.name(alias)).result().keySet().iterator().next());
            }
            Files.writeString(input, "scene,item,vector\n" + scene + ",invalid,\"[1,0]\"\n");
            try {
                LanguageEmbeddingTask.load(es, input.toString(), alias);
                fail("invalid vector must fail before activation");
            } catch (IllegalArgumentException expected) {
                assertEquals(second, es.indices().getAlias(a -> a.name(alias)).result().keySet().iterator().next());
            }
        } finally {
            for (String index : es.indices().get(i -> i.index(alias + "-*")).result().keySet()) {
                es.indices().delete(i -> i.index(index));
            }
            if (es.indices().exists(i -> i.index(scheduled)).value()) {
                es.indices().delete(i -> i.index(scheduled));
            }
            es._transport().close();
            Files.deleteIfExists(input);
        }
    }
}
