package com.openrec.example.task;

import com.openrec.proto.model.Item;
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
public final class RedisItemTask implements InitTask {

    @Override
    public String name() {
        return "redis-item";
    }

    @Override
    public List<Path> inputs(InitContext context) {
        return List.of(context.data("item.csv"));
    }

    @Override
    public void execute(InitContext context) {
        RedisTemplate redisTemplate = context.redis();
        try (Reader reader = Files.newBufferedReader(context.data("item.csv"))) {
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
}
