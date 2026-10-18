package com.openrec.example.task;

import com.openrec.proto.model.User;
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
public final class RedisUserTask implements InitTask {

    @Override
    public String name() {
        return "redis-user";
    }

    @Override
    public List<Path> inputs(InitContext context) {
        return List.of(context.data("user.csv"));
    }

    @Override
    public void execute(InitContext context) {
        RedisTemplate redisTemplate = context.redis();
        try (Reader reader = Files.newBufferedReader(context.data("user.csv"))) {
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
}
