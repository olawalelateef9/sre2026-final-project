package com.techbleat.bank.service;

import com.techbleat.bank.model.Account;
import com.techbleat.bank.repo.AccountRepository;
import com.techbleat.bank.repo.BankTransactionRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.web.server.ResponseStatusException;

import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class TransactionServiceTest {

    @Mock
    private AccountRepository accountRepository;

    @Mock
    private BankTransactionRepository transactionRepository;

    @Mock
    private KafkaTemplate<String, Object> kafkaTemplate;

    @InjectMocks
    private TransactionService service;

    @Test
    void rejectsNonPositiveAndNonFiniteAmounts() {
        for (Double amount : new Double[]{null, 0.0, -5.0, Double.NaN, Double.POSITIVE_INFINITY}) {
            ResponseStatusException error = assertThrows(ResponseStatusException.class,
                    () -> service.withdraw("alice", amount));
            assertEquals(400, error.getStatusCode().value());
        }
        verify(accountRepository, never()).save(any());
    }

    @Test
    void rejectsTransferToSelf() {
        ResponseStatusException error = assertThrows(ResponseStatusException.class,
                () -> service.transfer("alice", "alice", 10.0, null));
        assertEquals(400, error.getStatusCode().value());
        verify(accountRepository, never()).save(any());
    }

    @Test
    void rejectsTransferWithInsufficientFunds() {
        when(accountRepository.findByIdForUpdate("alice")).thenReturn(Optional.of(account("alice", 5.0)));
        when(accountRepository.findByIdForUpdate("bob")).thenReturn(Optional.of(account("bob", 0.0)));

        ResponseStatusException error = assertThrows(ResponseStatusException.class,
                () -> service.transfer("alice", "bob", 10.0, null));
        assertEquals(400, error.getStatusCode().value());
        verify(accountRepository, never()).save(any());
    }

    @Test
    void rejectsTransferToUnknownAccount() {
        when(accountRepository.findByIdForUpdate("alice")).thenReturn(Optional.of(account("alice", 50.0)));
        when(accountRepository.findByIdForUpdate("zed")).thenReturn(Optional.empty());

        ResponseStatusException error = assertThrows(ResponseStatusException.class,
                () -> service.transfer("alice", "zed", 10.0, null));
        assertEquals(404, error.getStatusCode().value());
        verify(accountRepository, never()).save(any());
    }

    private static Account account(String userId, double balance) {
        Account account = new Account();
        account.setUserId(userId);
        account.setBalance(balance);
        return account;
    }
}
