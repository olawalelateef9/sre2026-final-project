package com.techbleat.bank.service;

import com.techbleat.bank.model.Account;
import com.techbleat.bank.model.BankTransaction;
import com.techbleat.bank.repo.AccountRepository;
import com.techbleat.bank.repo.BankTransactionRepository;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.messaging.Message;
import org.springframework.messaging.support.MessageBuilder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import redis.clients.jedis.Jedis;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@Service
public class TransactionService {

    private static final Logger logger = LoggerFactory.getLogger(TransactionService.class);

    @Autowired
    private AccountRepository accountRepository;

    @Autowired
    private BankTransactionRepository transactionRepository;

    @Autowired
    private KafkaTemplate<String, Object> kafkaTemplate;

    @Value("${REDIS_HOST:redis}")
    private String redisHost;

    @Value("${REDIS_PORT:6379}")
    private int redisPort;

    // Writes run in one database transaction: if the Kafka publish fails, the balance change rolls back.
    @Transactional
    public Map<String, Object> deposit(String userId, Double amount) {
        validateAmount(amount);
        Account account = getAccountForUpdate(userId);

        account.setBalance(account.getBalance() + amount);
        accountRepository.save(account);

        saveTransaction(userId, "DEPOSIT", amount, "cash deposit");
        publishEvent(userId, "DEPOSIT", amount);
        cacheBalance(userId, account.getBalance());

        return Map.of("message", "Deposit successful", "balance", account.getBalance());
    }

    @Transactional
    public Map<String, Object> withdraw(String userId, Double amount) {
        validateAmount(amount);
        Account account = getAccountForUpdate(userId);

        if (account.getBalance() < amount) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Insufficient funds");
        }

        account.setBalance(account.getBalance() - amount);
        accountRepository.save(account);

        saveTransaction(userId, "WITHDRAW", amount, "cash withdrawal");
        publishEvent(userId, "WITHDRAW", amount);
        cacheBalance(userId, account.getBalance());

        return Map.of("message", "Withdrawal successful", "balance", account.getBalance());
    }

    @Transactional
    public Map<String, Object> transfer(String fromUserId, String toUserId, Double amount, String reference) {
        validateAmount(amount);
        if (toUserId == null || toUserId.isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Destination account is required");
        }
        if (toUserId.equals(fromUserId)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Cannot transfer to the same account");
        }

        // Lock both rows in a fixed order so concurrent opposite transfers cannot deadlock.
        boolean fromFirst = fromUserId.compareTo(toUserId) < 0;
        Account first = getAccountForUpdate(fromFirst ? fromUserId : toUserId);
        Account second = getAccountForUpdate(fromFirst ? toUserId : fromUserId);
        Account fromAccount = fromFirst ? first : second;
        Account toAccount = fromFirst ? second : first;

        if (fromAccount.getBalance() < amount) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Insufficient funds");
        }

        fromAccount.setBalance(fromAccount.getBalance() - amount);
        toAccount.setBalance(toAccount.getBalance() + amount);

        accountRepository.save(fromAccount);
        accountRepository.save(toAccount);

        saveTransaction(fromUserId, "TRANSFER_OUT", amount, reference == null || reference.isBlank() ? "to:" + toUserId : reference);
        saveTransaction(toUserId, "TRANSFER_IN", amount, reference == null || reference.isBlank() ? "from:" + fromUserId : reference);

        publishEvent(fromUserId, "TRANSFER_OUT", amount);
        publishEvent(toUserId, "TRANSFER_IN", amount);

        cacheBalance(fromUserId, fromAccount.getBalance());
        cacheBalance(toUserId, toAccount.getBalance());

        // The recipient's balance is not returned: it is another customer's data.
        return Map.of(
                "message", "Transfer successful",
                "fromBalance", fromAccount.getBalance()
        );
    }

    public Double getBalance(String userId) {
        try (Jedis jedis = new Jedis(redisHost, redisPort)) {
            String value = jedis.get("balance:" + userId);
            if (value != null) {
                return Double.parseDouble(value);
            }
        } catch (Exception ignored) {
        }

        Account account = getAccount(userId);
        cacheBalance(userId, account.getBalance());
        return account.getBalance();
    }

    public List<BankTransaction> getTransactions(String userId) {
        return transactionRepository.findByUserIdOrderByCreatedAtDesc(userId);
    }

    private Account getAccount(String userId) {
        return accountRepository.findById(userId)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "Account not found"));
    }

    private Account getAccountForUpdate(String userId) {
        return accountRepository.findByIdForUpdate(userId)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "Account not found"));
    }

    private void validateAmount(Double amount) {
        if (amount == null || amount.isNaN() || amount.isInfinite() || amount <= 0) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Amount must be greater than zero");
        }
    }

    private void saveTransaction(String userId, String type, Double amount, String reference) {
        BankTransaction tx = new BankTransaction();
        tx.setUserId(userId);
        tx.setTransactionType(type);
        tx.setAmount(amount);
        tx.setReference(reference);
        transactionRepository.save(tx);
    }

    private void publishEvent(String userId, String eventType, Double amount) {
        Map<String, Object> event = new HashMap<>();
        event.put("userId", userId);
        event.put("eventType", eventType);
        event.put("amount", amount);
        event.put("timestamp", Instant.now().toString());

        try {
            // Send to Kafka and wait for completion (with timeout) to catch errors before response
            var sendFuture = kafkaTemplate.send("banking-transactions", userId, event);
            var result = sendFuture.get(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            logger.info("Kafka event published successfully - User: {}, Type: {}, Amount: {}", 
                userId, eventType, amount);
        } catch (java.util.concurrent.TimeoutException ex) {
            logger.error("Kafka send timeout - User: {}, Type: {}, Amount: {}", userId, eventType, amount, ex);
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "Transaction could not be recorded", ex);
        } catch (Exception ex) {
            logger.error("Failed to publish Kafka event - User: {}, Type: {}, Amount: {}, Error: {}", 
                userId, eventType, amount, ex.getMessage(), ex);
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "Transaction could not be recorded", ex);
        }
    }

    private void cacheBalance(String userId, Double balance) {
        try (Jedis jedis = new Jedis(redisHost, redisPort)) {
            jedis.set("balance:" + userId, String.valueOf(balance));
        } catch (Exception ignored) {
        }
    }
}
