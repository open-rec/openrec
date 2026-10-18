package com.openrec.example.task;

import co.elastic.clients.elasticsearch.ElasticsearchClient;
import co.elastic.clients.elasticsearch.core.BulkRequest;
import co.elastic.clients.elasticsearch.indices.CreateIndexRequest;
import co.elastic.clients.elasticsearch.indices.DeleteIndexRequest;
import co.elastic.clients.elasticsearch.indices.ExistsRequest;
import co.elastic.clients.transport.endpoints.BooleanResponse;
import com.openrec.example.util.JsonUtil;
import com.openrec.proto.model.VectorResult;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVRecord;
import org.apache.commons.lang3.tuple.Pair;
import java.io.IOException;
import java.io.Reader;
import java.io.StringReader;
import java.nio.file.Files;
import java.util.*;
import com.openrec.example.InitContext;
import java.nio.file.Path;

@Slf4j
public final class SequenceEmbeddingTask implements InitTask {
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


    @Override
    public String name() {
        return "es-item-sequence-embedding";
    }

    @Override
    public List<Path> inputs(InitContext context) {
        return List.of(context.model("recall/item/item_seq_emb.csv"));
    }

    @Override
    public void execute(InitContext context) {
        ElasticsearchClient esClient = context.elasticsearch();
        try (Reader reader = Files.newBufferedReader(context.model("recall/item/item_seq_emb.csv"))) {
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
                    throw new IllegalStateException(indexName + " create failed");
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
                        if (esClient.bulk(bulkReqBuilder.build()).errors()) {
                            throw new IllegalStateException(indexName + " bulk load failed");
                        }
                        bulkReqBuilder = new BulkRequest.Builder();
                        count = 0;
                    }
                }
                if (count > 0) {
                    if (esClient.bulk(bulkReqBuilder.build()).errors()) {
                        throw new IllegalStateException(indexName + " bulk load failed");
                    }
                }
            }
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init embedding data finished");
    }
}
