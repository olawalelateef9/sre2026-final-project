package com.techbleat.bank.repo;

import com.techbleat.bank.model.Account;
import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;

public interface AccountRepository extends JpaRepository<Account, String> {

    /** Locks the account row until the surrounding transaction ends, preventing lost balance updates. */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select a from Account a where a.userId = :userId")
    Optional<Account> findByIdForUpdate(@Param("userId") String userId);
}
