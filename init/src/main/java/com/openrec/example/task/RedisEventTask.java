package com.openrec.example.task;

import com.openrec.proto.model.Event;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVRecord;
import org.springframework.data.redis.core.RedisTemplate;
import java.io.IOException;
import java.io.Reader;
import java.nio.file.Files;
import java.util.*;
import com.openrec.example.InitContext;
import java.nio.file.Path;

@Slf4j
public final class RedisEventTask implements InitTask {

    @Override
    public String name() {
        return "redis-event";
    }

    @Override
    public List<Path> inputs(InitContext context) {
        return List.of(context.data("event.csv"));
    }

    @Override
    public void execute(InitContext context) {
        RedisTemplate redisTemplate = context.redis();
        try (Reader reader = Files.newBufferedReader(context.data("event.csv"))) {
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
}
