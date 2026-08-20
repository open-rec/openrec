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
    private static String testRecallEmbeddingData;
    private static String testRecallHotData;
    private static String testRecallNewData;

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
            "    \"score\": {\"type\": \"double\"},\n" +
            "    \"publish_time\": {\"type\": \"long\"}\n" +
            "  }},\n" +
            "  \"aliases\": {\"%s\": {}}\n" +
            "}";

    static {
        useDataDir(DEFAULT_DATA_DIR);
    }

    private static void useDataDir(String dataDir) {
        testDataDir = Paths.get(dataDir).isAbsolute() ? dataDir
                : System.getProperty("user.dir") + "/" + dataDir;
        testItemData = testDataDir + "/item.csv";
        testUserData = testDataDir + "/user.csv";
        testEventData = testDataDir + "/event.csv";

        String recallDataDir = testDataDir + "/recall";
        testRecallI2iData = recallDataDir + "/i2i.csv";
        testRecallEmbeddingData = recallDataDir + "/embedding.csv";
        testRecallHotData = recallDataDir + "/hot.csv";
        testRecallNewData = recallDataDir + "/new.csv";
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

    private static void initRedisI2iData(RedisTemplate redisTemplate) {
        try {
            Reader reader = Files.newBufferedReader(Paths.get(testRecallI2iData));
            Iterable<CSVRecord> records = CSVFormat.DEFAULT
                    .withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true)
                    .withTrim()
                    .parse(reader);
            for (CSVRecord record : records) {
                String scene = record.get("scene");
                String leftItem = record.get("left_item");
                String rightItem = record.get("right_item");
                Double score = Double.valueOf(record.get("score"));
                redisTemplate.opsForZSet().add(String.format("i2i:{%s}:%s", leftItem, scene), rightItem, score);
            }
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init i2i data finished");
    }

    private static void initRedisHotData(RedisTemplate redisTemplate) {
        try {
            Reader reader = Files.newBufferedReader(Paths.get(testRecallHotData));
            Iterable<CSVRecord> records = CSVFormat.DEFAULT
                    .withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true)
                    .withTrim()
                    .parse(reader);
            for (CSVRecord record : records) {
                String scene = record.get("scene");
                String item = record.get("item");
                Double score = Double.valueOf(record.get("score"));
                redisTemplate.opsForZSet().add(String.format("hot:{%s}", scene), item, score);
            }
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init hot data finished");
    }

    private static void initRedisNewData(RedisTemplate redisTemplate) {
        // NewNode queries this ZSET by a Unix-time window. Preserve the input's normalized
        // freshness ordering while projecting it onto the current timestamp range. Capturing the
        // timestamp once keeps scores comparable across every row in this initialization run.
        double currentUnixTimestamp = System.currentTimeMillis() / 1000.0;
        try {
            Reader reader = Files.newBufferedReader(Paths.get(testRecallNewData));
            Iterable<CSVRecord> records = CSVFormat.DEFAULT
                    .withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true)
                    .withTrim()
                    .parse(reader);
            for (CSVRecord record : records) {
                String scene = record.get("scene");
                String item = record.get("item");
                Double score = Double.valueOf(record.get("score"));
                redisTemplate.opsForZSet().add(
                        String.format("new:{%s}", scene), item, score * currentUnixTimestamp);
            }
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init new data finished");
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
                String indexName = String.format("%s-item-vector-index", scene);

                ExistsRequest existsRequest = ExistsRequest.of(i -> i.index(indexName));
                BooleanResponse response = esClient.indices().exists(existsRequest);
                if (response.value()) {
                    DeleteIndexRequest deleteRequest = DeleteIndexRequest.of(i -> i.index(indexName));
                    esClient.indices().delete(deleteRequest);
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

    private static void initEsRecallData(ElasticsearchClient esClient, String kind, String csvPath) {
        String version = LocalDate.now(ZoneOffset.UTC).format(DateTimeFormatter.BASIC_ISO_DATE);
        String indexName = String.format("openrec-recall-%s-%s-r001", kind, version);
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
                if ("i2i".equals(kind)) {
                    document.put("left_item", record.get("left_item"));
                    document.put("right_item", record.get("right_item"));
                } else {
                    document.put("item", record.get("item"));
                    if ("new".equals(kind)) {
                        document.put("publish_time",
                                (long)(Double.valueOf(record.get("score")) * now));
                    }
                }
                String id = "i2i".equals(kind)
                        ? record.get("scene") + ":" + record.get("left_item") + ":" + record.get("right_item")
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

    public static void initRedisData(String host, int port) {
        RedisTemplate redisTemplate = RedisUtil.getRedis(host, port);
        if (redisTemplate == null) {
            log.error("redis init failed");
            return;
        }
        initRedisUserData(redisTemplate);
        initRedisItemData(redisTemplate);
        initRedisEventData(redisTemplate);

        initRedisI2iData(redisTemplate);
        initRedisHotData(redisTemplate);
        initRedisNewData(redisTemplate);
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
        initEsRecallData(esClient, "i2i", testRecallI2iData);
        initEsEmbeddingData(esClient);
        log.info("init es data finished");
    }


    public static void main(String[] args) {
        if (args.length != 6 && args.length != 7) {
            log.error("Usage: java InitStandalone <redis_host> <redis_port> <es_host> <es_port> <es_user> <es_password> [data_dir]");
            return;
        }

        if (args.length == 7) {
            useDataDir(args[6]);
        }
        if (!Files.isDirectory(Paths.get(testDataDir))) {
            log.error("data dir not found: {}, please run it from the example repo root, "
                    + "or pass the data dir as the 7th argument", testDataDir);
            return;
        }
        log.info("init data from dir: {}", testDataDir);

        try {
            String redisHost = args[0];
            int redisPort = Integer.valueOf(args[1]);
            initRedisData(redisHost, redisPort);
        } catch (Exception e) {
            log.error("init redis data failed! exception:{}", e.getMessage());
            e.printStackTrace();
        }

        try {
            String esHost = args[2];
            int esPort = Integer.valueOf(args[3]);
            String esUser = args[4];
            String esPassword = args[5];
            initEsData(esHost, esPort, esUser, esPassword);
        } catch (Exception e) {
            log.error("init es data failed! exception:{}", e.getMessage());
            e.printStackTrace();
        }
        System.exit(0);
    }
}
