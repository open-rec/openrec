package com.openrec.example.task;

import co.elastic.clients.elasticsearch.ElasticsearchClient;
import co.elastic.clients.elasticsearch.core.BulkRequest;
import com.openrec.example.util.JsonUtil;
import com.openrec.proto.model.VectorResult;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVRecord;
import java.io.IOException;
import java.io.Reader;
import java.io.StringReader;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.*;
import com.openrec.example.InitContext;
import java.nio.file.Path;

@Slf4j
public final class LanguageEmbeddingTask implements InitTask {

    @Override
    public String name() {
        return "es-item-title-embedding";
    }

    @Override
    public List<Path> inputs(InitContext context) {
        return List.of(context.model("recall/item/item_title_emb.csv"));
    }

    @Override
    public void execute(InitContext context) {
        load(context.elasticsearch(), context.model("recall/item/item_title_emb.csv").toString());
    }

    public static List<Double> languageVector(String json, int dimensions) {
        List<?> values = JsonUtil.jsonToObj(json, List.class);
        if (values == null || values.size() != dimensions) {
            throw new IllegalArgumentException("language vector dimension mismatch");
        }
        List<Double> result = new ArrayList<>();
        double norm = 0;
        for (Object value : values) {
            if (!(value instanceof Number) || !Double.isFinite(((Number) value).doubleValue())) {
                throw new IllegalArgumentException("language vector must contain finite numbers");
            }
            double number = ((Number) value).doubleValue();
            result.add(number);
            norm += number * number;
        }
        if (Math.abs(norm - 1) > 0.001) {
            throw new IllegalArgumentException("language vector must be L2-normalized");
        }
        return result;
    }

    public static void load(ElasticsearchClient esClient, String csvPath) {
        load(esClient, csvPath, "query-title-emb-index");
    }

    public static void load(ElasticsearchClient esClient, String csvPath, String alias) {
        int dimensions = Integer.parseInt(System.getenv().getOrDefault("EMBEDDING_DIMENSIONS", "1024"));
        String model = System.getenv().getOrDefault("EMBEDDING_MODEL", "Qwen/Qwen3-Embedding-0.6B");
        String index = alias + "-" + UUID.randomUUID();
        Map<String, String> fingerprints = new HashMap<>();
        try (Reader reader = Files.newBufferedReader(Paths.get(csvPath))) {
            java.security.MessageDigest digest = java.security.MessageDigest.getInstance("SHA-256");
            Iterable<CSVRecord> records = CSVFormat.DEFAULT.withFirstRecordAsHeader()
                .withIgnoreEmptyLines(true).withTrim().parse(reader);
            BulkRequest.Builder bulk = new BulkRequest.Builder();
            int batchCount = 0;
            for (CSVRecord record : records) {
                String item = record.get("item");
                if (item.isBlank()) {
                    throw new IllegalArgumentException("invalid language vector item");
                }
                List<Double> vector = languageVector(record.get("vector"), dimensions);
                String fingerprint = HexFormat.of().formatHex(digest.digest(
                    JsonUtil.objToJson(vector).getBytes(java.nio.charset.StandardCharsets.UTF_8)));
                String previous = fingerprints.get(item);
                if (previous != null) {
                    if (!previous.equals(fingerprint)) {
                        throw new IllegalArgumentException("conflicting language vectors for item " + item);
                    }
                    continue;
                }
                if (fingerprints.isEmpty()) {
                    Map<String, Object> mapping = Map.of("mappings", Map.of(
                        "_meta", Map.of("embedding_model", model, "source", "item_title_emb.csv"),
                        "properties", Map.of("id", Map.of("type", "keyword"),
                            "vector", Map.of("type", "dense_vector", "dims", dimensions,
                                "index", true, "similarity", "cosine"))));
                    if (!esClient.indices().create(i -> i.index(index)
                            .withJson(new StringReader(JsonUtil.objToJson(mapping)))).acknowledged()) {
                        throw new IllegalStateException("language vector index creation failed");
                    }
                }
                fingerprints.put(item, fingerprint);
                bulk.operations(op -> op.index(i -> i.index(index).id(item)
                    .document(new VectorResult(item, vector))));
                if (++batchCount == 100) {
                    if (esClient.bulk(bulk.build()).errors()) {
                        throw new IllegalStateException("language vector bulk load failed");
                    }
                    bulk = new BulkRequest.Builder();
                    batchCount = 0;
                }
            }
            if (batchCount > 0 && esClient.bulk(bulk.build()).errors()) {
                throw new IllegalStateException("language vector bulk load failed");
            }
            if (fingerprints.isEmpty()) {
                throw new IllegalStateException("empty language vector input");
            }
            esClient.indices().refresh(i -> i.index(index));
            if (esClient.count(c -> c.index(index)).count() != fingerprints.size()) {
                throw new IllegalStateException("language vector count mismatch");
            }
            // Bootstrap and scheduled releases share one alias, regardless of physical naming.
            Set<String> previous = esClient.indices().existsAlias(a -> a.name(alias)).value()
                ? esClient.indices().getAlias(a -> a.name(alias)).result().keySet() : Collections.emptySet();
            esClient.indices().updateAliases(a -> {
                for (String old : previous) {
                    a.actions(action -> action.remove(remove -> remove.index(old).alias(alias)));
                }
                return a.actions(action -> action.add(add -> add.index(index).alias(alias)));
            });
        } catch (IOException | java.security.NoSuchAlgorithmException e) {
            throw new RuntimeException(e);
        }
        log.info("init global language embeddings finished: {} items, model {}", fingerprints.size(), model);
    }
}
