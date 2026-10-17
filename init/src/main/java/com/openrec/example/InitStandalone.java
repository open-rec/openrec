package com.openrec.example;

import co.elastic.clients.elasticsearch.ElasticsearchClient;
import co.elastic.clients.elasticsearch.core.BulkRequest;
import co.elastic.clients.elasticsearch.indices.CreateIndexRequest;
import co.elastic.clients.elasticsearch.indices.DeleteIndexRequest;
import co.elastic.clients.elasticsearch.indices.ExistsRequest;
import co.elastic.clients.transport.endpoints.BooleanResponse;
import com.openrec.example.util.EsUtil;
import com.openrec.example.util.JsonUtil;
import com.openrec.example.util.RedisUtil;
import com.openrec.proto.model.Event;
import com.openrec.proto.model.Item;
import com.openrec.proto.model.User;
import com.openrec.proto.model.VectorResult;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVRecord;
import org.apache.commons.lang3.tuple.Pair;
import org.springframework.data.redis.core.RedisTemplate;

import java.io.IOException;
import java.io.Reader;
import java.io.StringReader;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;

@Slf4j
public class InitStandalone {

    /**
     * the sample data shipped with this repo, relative to the working directory.
     * override it by the optional 7th argument, eg: ../data/douban
     */
    private static final String DEFAULT_DATA_DIR = "data/test";

    private static String testDataDir;
    private static String testItemData;
    private static String testUserData;
    private static String testEventData;
    private static String testRecallI2iData;
    private static String testRecallContentI2iData;
    private static String testRecallUserCfU2iData;
    private static String testRecallEmbeddingData;
    private static String testRecallHotData;
    private static String testRecallNewData;
    private static String featureDataDir;
    private static String titleEmbeddingData;
    private static String userRecallDataDir;

    private static final String ITEM_VECTOR_INDEX = "{\n" +
            "  \"mappings\": {\n" +
            "    \"properties\": {\n" +
            "      \"vector\": {\n" +
            "        \"type\": \"dense_vector\",\n" +
            "        \"dims\": 10,\n" +
            "        \"index\": true,\n" +
            "        \"similarity\": \"l2_norm\"\n" +
            "      },\n" +
            "      \"id\": {\n" +
            "        \"type\": \"keyword\"\n" +
            "      }\n" +
            "    }\n" +
            "  }\n" +
            "}";

    private static final String RECALL_INDEX = "{\n" +
            "  \"mappings\": {\"properties\": {\n" +
            "    \"scene\": {\"type\": \"keyword\"},\n" +
            "    \"item\": {\"type\": \"keyword\"},\n" +
            "    \"left_item\": {\"type\": \"keyword\"},\n" +
    "    \"right_item\": {\"type\": \"keyword\"},\n" +
            "    \"user\": {\"type\": \"keyword\"},\n" +
            "    \"left_user\": {\"type\": \"keyword\"},\n" +
            "    \"right_user\": {\"type\": \"keyword\"},\n" +
            "    \"score\": {\"type\": \"double\"},\n" +
            "    \"publish_time\": {\"type\": \"long\"}\n" +
            "  }},\n" +
            "  \"aliases\": {\"%s\": {}}\n" +
            "}";

    private static String itemSearchData;
    private static String userSearchData;

    static Map<String, Object> searchDocument(CSVRecord record, String entity) {
        if (!entity.equals("item") && !entity.equals("user")) {
            throw new IllegalArgumentException("search entity must be item or user");
        }
        Map<String, Object> document = new HashMap<>();
        for (String field : Arrays.asList("scene", entity, "text")) {
            String value = record.get(field);
            if (value.isBlank()) {
                throw new IllegalArgumentException("empty search field: " + field);
            }
            document.put(field, value);
        }
        return document;
    }

    static {
        useDataDir(DEFAULT_DATA_DIR);
        useModelDir(System.getProperty("user.dir") + "/../model");
    }

    private static void useDataDir(String dataDir) {
        testDataDir = Paths.get(dataDir).isAbsolute() ? dataDir
                : System.getProperty("user.dir") + "/" + dataDir;
        testItemData = testDataDir + "/item.csv";
        testUserData = testDataDir + "/user.csv";
        testEventData = testDataDir + "/event.csv";

    }

    private static void useModelDir(String modelDir) {
        String absolute = Paths.get(modelDir).isAbsolute() ? modelDir
                : System.getProperty("user.dir") + "/" + modelDir;
        featureDataDir = absolute + "/rank/item/lr";
        String recallDataDir = absolute + "/recall/item";
        testRecallI2iData = recallDataDir + "/item_cf_i2i.csv";
        testRecallContentI2iData = recallDataDir + "/content_i2i.csv";
        testRecallUserCfU2iData = recallDataDir + "/user_cf_u2i.csv";
        testRecallEmbeddingData = recallDataDir + "/item_seq_emb.csv";
        titleEmbeddingData = recallDataDir + "/item_title_emb.csv";
        testRecallHotData = recallDataDir + "/hot.csv";
        testRecallNewData = recallDataDir + "/new.csv";
        itemSearchData = recallDataDir + "/text_search.csv";
        userSearchData = absolute + "/recall/user/text_search.csv";
        userRecallDataDir = absolute + "/recall/user";
    }

    private static void initRedisItemData(RedisTemplate redisTemplate) {
        try {
            Reader reader = Files.newBufferedReader(Paths.get(testItemData));
            Iterable<CSVRecord> records = CSVFormat.DEFAULT
                    .withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true)
                    .withTrim()
                    .parse(reader);
            for (CSVRecord record : records) {
                Item item = new Item();
                item.setId(record.get("id"));
                item.setTitle(record.get("title"));
                item.setCategory(record.get("category"));
                item.setTags(record.get("tags"));
                item.setScene(record.get("scene"));
                item.setPubTime(record.get("pub_time"));
                item.setModifyTime(record.get("modify_time"));
                item.setExpireTime(record.get("expire_time"));
                item.setStatus(Integer.parseInt(record.get("status")));
                item.setWeight(Double.valueOf(record.get("weight")).intValue());
                item.setExtFields(record.get("ext_fields"));
                redisTemplate.opsForValue().set(String.format("item:{%s}", item.getId()), item);
            }
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init item data finished");
    }

    private static void initRedisUserData(RedisTemplate redisTemplate) {
        try {
            Reader reader = Files.newBufferedReader(Paths.get(testUserData));
            Iterable<CSVRecord> records = CSVFormat.DEFAULT
                    .withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true)
                    .withTrim()
                    .parse(reader);
            for (CSVRecord record : records) {
                User user = new User();
                user.setId(record.get("id"));
                user.setDeviceId(record.get("device_id"));
                user.setName(record.get("name"));
                user.setGender(record.get("gender"));
                user.setAge(Integer.parseInt(record.get("age")));
                user.setCountry(record.get("country"));
                user.setCity(record.get("city"));
                user.setPhone(record.get("phone"));
                user.setTags(Arrays.asList(record.get("tags").split(",")));
                user.setRegisterTime(record.get("register_time"));
                user.setLoginTime(record.get("login_time"));
                user.setExtFields(record.get("ext_fields"));
                redisTemplate.opsForValue().set(String.format("user:{%s}", user.getId()), user);
            }
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init user data finished");
    }

    private static void initRedisEventData(RedisTemplate redisTemplate) {
        try {
            Reader reader = Files.newBufferedReader(Paths.get(testEventData));
            Iterable<CSVRecord> records = CSVFormat.DEFAULT
                    .withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true)
                    .withTrim()
                    .parse(reader);
            for (CSVRecord record : records) {
                Event event = new Event();
                event.setUserId(record.get("user_id"));
                event.setItemId(record.get("item_id"));
                event.setTraceId(record.get("trace_id"));
                event.setScene(record.get("scene"));
                event.setType(record.get("type"));
                event.setValue(record.get("value"));
                event.setTime(record.get("time"));
                event.setLogin(Boolean.parseBoolean(record.get("is_login")));
                event.setExtFields(record.get("ext_fields"));
                redisTemplate.opsForZSet().add(
                        String.format("event:{%s}:%s:%s", event.getUserId(), event.getScene(), event.getType()),
                        event.getItemId(),
                        Double.valueOf(event.getTime()));
            }
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init event data finished");
    }

    private static void initRedisFeatureData(RedisTemplate redisTemplate, String entityType,
                                             String fileName) {
        java.nio.file.Path path = Paths.get(featureDataDir, fileName);
        if (!Files.isRegularFile(path)) {
            log.warn("feature snapshot not found, skipping: {}", path);
            return;
        }
        int count = 0;
        try (Reader reader = Files.newBufferedReader(path)) {
            Iterable<CSVRecord> records = CSVFormat.DEFAULT.withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true).withTrim().parse(reader);
            for (CSVRecord record : records) {
                String entityId = record.get("id");
                long asOfTime = record.isMapped("as_of_time") && !record.get("as_of_time").isEmpty()
                        ? Double.valueOf(record.get("as_of_time")).longValue() : 0L;
                Map<String, Double> features = new LinkedHashMap<>();
                for (String column : record.toMap().keySet()) {
                    if (column.startsWith("event_")) {
                        String value = record.get(column);
                        features.put(column, value.isEmpty() ? 0.0 : Double.valueOf(value));
                    }
                }
                Map<String, Object> snapshot = new LinkedHashMap<>();
                snapshot.put("entityType", entityType);
                snapshot.put("entityId", entityId);
                snapshot.put("asOfTime", asOfTime);
                snapshot.put("features", features);
                redisTemplate.opsForValue().set(
                        String.format("feature:%s:{%s}", entityType, entityId),
                        snapshot);
                count++;
            }
        } catch (IOException | NumberFormatException e) {
            throw new RuntimeException("invalid feature snapshot " + path, e);
        }
        log.info("init {} feature snapshots finished: {} rows", entityType, count);
    }

    private static void initEsEmbeddingData(ElasticsearchClient esClient) {
        try {
            Reader reader = Files.newBufferedReader(Paths.get(testRecallEmbeddingData));
            Iterable<CSVRecord> records = CSVFormat.DEFAULT
                    .withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true)
                    .withTrim()
                    .parse(reader);
            Map<String, List<Pair<String, List<Double>>>> sceneItemVectorsMap = new HashMap<>();
            for (CSVRecord record : records) {
                String scene = record.get("scene");
                String itemId = record.get("item");
                List<Double> vector = JsonUtil.jsonToObj(record.get("vector"), List.class);
                if (!sceneItemVectorsMap.containsKey(scene)) {
                    sceneItemVectorsMap.put(scene, new LinkedList<>());
                }
                sceneItemVectorsMap.get(scene).add(Pair.of(itemId, vector));
            }

            for (Map.Entry<String, List<Pair<String, List<Double>>>> entry : sceneItemVectorsMap.entrySet()) {
                String scene = entry.getKey();
                String indexName = String.format("%s-item-seq-emb-index", scene);

                // The daily publisher migrates this legacy serving index to an alias pointing at a
                // versioned index. Elasticsearch deliberately rejects DELETE /{alias}; resolve and
                // delete its concrete targets first so repeated standalone/cluster bootstrap runs
                // remain idempotent regardless of which representation currently exists.
                BooleanResponse aliasExists = esClient.indices().existsAlias(a -> a.name(indexName));
                if (aliasExists.value()) {
                    Set<String> aliasedIndexes = new HashSet<>(esClient.indices()
                            .getAlias(a -> a.name(indexName)).result().keySet());
                    for (String aliasedIndex : aliasedIndexes) {
                        esClient.indices().delete(DeleteIndexRequest.of(i -> i.index(aliasedIndex)));
                    }
                } else {
                    ExistsRequest existsRequest = ExistsRequest.of(i -> i.index(indexName));
                    BooleanResponse response = esClient.indices().exists(existsRequest);
                    if (response.value()) {
                        esClient.indices().delete(DeleteIndexRequest.of(i -> i.index(indexName)));
                    }
                }
                CreateIndexRequest indexRequest = CreateIndexRequest
                        .of(i -> i.index(indexName).withJson(new StringReader(ITEM_VECTOR_INDEX)));
                boolean created = esClient.indices().create(indexRequest).acknowledged();
                if (!created) {
                    log.error("{} create failed", indexName);
                    return;
                }

                List<Pair<String, List<Double>>> itemVectors = entry.getValue();
                int total = itemVectors.size();
                int batch = 10;
                int count = 0;
                BulkRequest.Builder bulkReqBuilder = new BulkRequest.Builder();
                for (int i = 0; i < total; i++) {
                    int finalI = i;
                    count++;
                    bulkReqBuilder.operations(op -> op.index(o -> o.index(indexName)
                            .id(String.valueOf(finalI))
                            .document(new VectorResult(
                                    String.valueOf(itemVectors.get(finalI).getKey()),
                                    itemVectors.get(finalI).getValue()))));
                    if (count == batch) {
                        esClient.bulk(bulkReqBuilder.build());
                        bulkReqBuilder = new BulkRequest.Builder();
                        count = 0;
                    }
                }
                if (count > 0) {
                    esClient.bulk(bulkReqBuilder.build());
                }
            }
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init embedding data finished");
    }

    static List<Double> languageVector(String json, int dimensions) {
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

    static void initEsLanguageEmbeddingData(ElasticsearchClient esClient, String csvPath) {
        initEsLanguageEmbeddingData(esClient, csvPath, "query-title-emb-index");
    }

    static void initEsLanguageEmbeddingData(ElasticsearchClient esClient, String csvPath, String alias) {
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

    static String bootstrapRecallIndexName(String kind, String version) {
        // Reserve r000 for fixture imports; the scheduled publisher starts at r001.
        return String.format("openrec-recall-%s-%s-r000", kind, version);
    }

    private static void initEsRecallData(ElasticsearchClient esClient, String kind, String csvPath) {
        String version = LocalDate.now(ZoneOffset.UTC).format(DateTimeFormatter.BASIC_ISO_DATE);
        String indexName = bootstrapRecallIndexName(kind, version);
        String aliasName = String.format("openrec-recall-%s-active", kind);
        try {
            BooleanResponse aliasExists = esClient.indices().existsAlias(a -> a.name(aliasName));
            if (aliasExists.value()) {
                Set<String> aliasedIndexes = esClient.indices().getAlias(a -> a.name(aliasName))
                        .result().keySet();
                for (String aliasedIndex : aliasedIndexes) {
                    esClient.indices().delete(DeleteIndexRequest.of(i -> i.index(aliasedIndex)));
                }
            }
            BooleanResponse currentIndexExists = esClient.indices()
                    .exists(ExistsRequest.of(i -> i.index(indexName)));
            if (currentIndexExists.value()) {
                esClient.indices().delete(DeleteIndexRequest.of(i -> i.index(indexName)));
            }
            boolean created = esClient.indices().create(CreateIndexRequest.of(i -> i.index(indexName)
                    .withJson(new StringReader(String.format(RECALL_INDEX, aliasName))))).acknowledged();
            if (!created) {
                throw new IllegalStateException(indexName + " create failed");
            }

            long now = System.currentTimeMillis() / 1000;
            Reader reader = Files.newBufferedReader(Paths.get(csvPath));
            Iterable<CSVRecord> records = CSVFormat.DEFAULT.withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true).withTrim().parse(reader);
            BulkRequest.Builder bulk = new BulkRequest.Builder();
            int batchCount = 0;
            for (CSVRecord record : records) {
                Map<String, Object> document = new HashMap<>();
                document.put("scene", record.get("scene"));
                document.put("score", Double.valueOf(record.get("score")));
                if (kind.endsWith("i2i")) {
                    document.put("left_item", record.get("left_item"));
                    document.put("right_item", record.get("right_item"));
                } else if (kind.endsWith("u2u")) {
                    document.put("left_user", record.get("left_user"));
                    document.put("right_user", record.get("right_user"));
                } else if ("user-cf-u2i".equals(kind)) {
                    document.put("user", record.get("user"));
                    document.put("item", record.get("item"));
                } else {
                    document.put("item", record.get("item"));
                    if ("new".equals(kind)) {
                        document.put("publish_time",
                                (long)(Double.valueOf(record.get("score")) * now));
                    }
                }
                String id = kind.endsWith("i2i")
                        ? record.get("scene") + ":" + record.get("left_item") + ":" + record.get("right_item")
                        : kind.endsWith("u2u")
                        ? record.get("scene") + ":" + record.get("left_user") + ":" + record.get("right_user")
                        : "user-cf-u2i".equals(kind)
                        ? record.get("scene") + ":" + record.get("user") + ":" + record.get("item")
                        : record.get("scene") + ":" + record.get("item");
                bulk.operations(op -> op.index(idx -> idx.index(indexName).id(id).document(document)));
                batchCount++;
                if (batchCount == 1000) {
                    if (esClient.bulk(bulk.build()).errors()) {
                        throw new IllegalStateException(indexName + " bulk load failed");
                    }
                    bulk = new BulkRequest.Builder();
                    batchCount = 0;
                }
            }
            if (batchCount > 0 && esClient.bulk(bulk.build()).errors()) {
                throw new IllegalStateException(indexName + " bulk load failed");
            }
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init {} recall data finished: {} -> {}", kind, indexName, aliasName);
    }

    private static void initEsSearchData(ElasticsearchClient esClient, String entity, String csvPath) {
        String kind = entity + "-search";
        String version = LocalDate.now(ZoneOffset.UTC).format(DateTimeFormatter.BASIC_ISO_DATE);
        String indexName = bootstrapRecallIndexName(kind, version) + System.currentTimeMillis();
        String aliasName = "openrec-recall-" + kind + "-active";
        try (Reader reader = Files.newBufferedReader(Paths.get(csvPath))) {
            Iterable<CSVRecord> records = CSVFormat.DEFAULT.withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true).withTrim().parse(reader);
            esClient.indices().create(i -> i.index(indexName).mappings(m -> m
                    .properties("scene", v -> v.keyword(k -> k))
                    .properties(entity, v -> v.keyword(k -> k))
                    .properties("text", v -> v.text(t -> t.similarity("BM25")))));
            BulkRequest.Builder bulk = new BulkRequest.Builder();
            int batchCount = 0;
            long count = 0;
            for (CSVRecord record : records) {
                Map<String, Object> document = searchDocument(record, entity);
                String id = document.get("scene") + ":" + document.get(entity);
                bulk.operations(op -> op.index(idx -> idx.index(indexName).id(id).document(document)));
                count++;
                if (++batchCount == 1000) {
                    if (esClient.bulk(bulk.build()).errors()) {
                        throw new IllegalStateException(indexName + " bulk load failed");
                    }
                    bulk = new BulkRequest.Builder();
                    batchCount = 0;
                }
            }
            if (batchCount > 0 && esClient.bulk(bulk.build()).errors()) {
                throw new IllegalStateException(indexName + " bulk load failed");
            }
            esClient.indices().refresh(i -> i.index(indexName));
            if (count == 0 || esClient.count(c -> c.index(indexName)).count() != count) {
                throw new IllegalStateException(indexName + " document count mismatch or empty input");
            }
            List<String> previous = new ArrayList<>();
            if (esClient.indices().existsAlias(a -> a.name(aliasName)).value()) {
                previous.addAll(esClient.indices().getAlias(a -> a.name(aliasName)).result().keySet());
            }
            esClient.indices().updateAliases(a -> {
                for (String old : previous) {
                    a.actions(action -> action.remove(remove -> remove.index(old).alias(aliasName)));
                }
                return a.actions(action -> action.add(add -> add.index(indexName).alias(aliasName)));
            });
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init {} data finished: {} -> {}", kind, indexName, aliasName);
    }

    public static void initRedisData(String host, int port) {
        RedisTemplate redisTemplate = RedisUtil.getRedis(host, port);
        if (redisTemplate == null) {
            log.error("redis init failed");
            return;
        }
        initRedisUserData(redisTemplate);
        initRedisItemData(redisTemplate);
        initRedisEventData(redisTemplate);
        initRedisFeatureData(redisTemplate, "user", "user_feature.csv");
        initRedisFeatureData(redisTemplate, "item", "item_feature.csv");

        log.info("init redis data finished");
    }

    public static void initEsData(String host, int port, String user, String password) {
        ElasticsearchClient esClient = EsUtil.getEs(host, port, user, password);
        if (esClient == null) {
            log.error("es init failed");
            return;
        }
        initEsRecallData(esClient, "hot", testRecallHotData);
        initEsRecallData(esClient, "new", testRecallNewData);
        initEsRecallData(esClient, "item-cf-i2i", testRecallI2iData);
        initEsRecallData(esClient, "content-i2i", testRecallContentI2iData);
        initEsRecallData(esClient, "user-cf-u2i", testRecallUserCfU2iData);
        for (String kind : Arrays.asList("user-cf-u2u", "content-u2u", "user-als-u2u")) {
            initEsRecallData(esClient, kind, userRecallDataDir + "/" + kind.replace('-', '_') + ".csv");
        }
        initEsSearchData(esClient, "item", itemSearchData);
        initEsSearchData(esClient, "user", userSearchData);
        initEsEmbeddingData(esClient);
        if (Boolean.parseBoolean(System.getenv().getOrDefault("EMBEDDING_ENABLED", "false"))) {
            initEsLanguageEmbeddingData(esClient, titleEmbeddingData);
        }
        log.info("init es data finished");
    }


    public static void main(String[] args) {
        if (args.length < 6 || args.length > 8) {
            log.error("Usage: java InitStandalone <redis_host> <redis_port> <es_host> <es_port> "
                    + "<es_user> <es_password> [data_dir] [model_dir]");
            throw new IllegalArgumentException("expected Redis/Elasticsearch connection arguments");
        }

        if (args.length == 7) {
            useDataDir(args[6]);
        }
        if (args.length >= 8) {
            useDataDir(args[6]);
            useModelDir(args[7]);
        }
        if (!Files.isDirectory(Paths.get(testDataDir))) {
            log.error("data dir not found: {}, please run it from the example repo root, "
                    + "or pass the data dir as the 7th argument", testDataDir);
            throw new IllegalArgumentException("data directory does not exist: " + testDataDir);
        }
        log.info("init data from dir: {}", testDataDir);

        try {
            String redisHost = args[0];
            int redisPort = Integer.valueOf(args[1]);
            initRedisData(redisHost, redisPort);
        } catch (Exception e) {
            log.error("init redis data failed! exception:{}", e.getMessage());
            throw new IllegalStateException("Redis initialization failed", e);
        }

        try {
            String esHost = args[2];
            int esPort = Integer.valueOf(args[3]);
            String esUser = args[4];
            String esPassword = args[5];
            initEsData(esHost, esPort, esUser, esPassword);
        } catch (Exception e) {
            log.error("init es data failed! exception:{}", e.getMessage());
            throw new IllegalStateException("Elasticsearch initialization failed", e);
        }
        System.exit(0);
    }
}
