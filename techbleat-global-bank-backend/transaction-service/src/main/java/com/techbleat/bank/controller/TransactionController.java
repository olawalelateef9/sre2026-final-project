package com.techbleat.bank.controller;

import com.techbleat.bank.dto.AmountRequest;
import com.techbleat.bank.dto.TransferRequest;
import com.techbleat.bank.service.TransactionService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

/**
 * Every banking operation acts on the authenticated user (the token's
 * preferred_username). Path user IDs must match it; the legacy X-User-Id
 * header is only accepted when it matches it.
 */
@RestController
@RequestMapping("/")
public class TransactionController {

    private static final String CAN_VIEW = "hasRole('banking-customer')";
    private static final String CAN_TRANSACT = "hasRole('banking-customer') and hasRole('banking-transact')";

    @Autowired
    private TransactionService transactionService;

    @GetMapping("/health")
    public Object health() {
        return java.util.Map.of("status", "ok");
    }

    @PreAuthorize(CAN_TRANSACT)
    @PostMapping(value = "/transactions/deposit", consumes = "application/json")
    public Object deposit(Authentication auth,
                          @RequestHeader(value = "X-User-Id", required = false) String claimedUserId,
                          @RequestBody AmountRequest request) {
        return transactionService.deposit(callerMatching(auth, claimedUserId), request.getAmount());
    }

    @PreAuthorize(CAN_TRANSACT)
    @PostMapping(value = "/transactions/withdraw", consumes = "application/json")
    public Object withdraw(Authentication auth,
                           @RequestHeader(value = "X-User-Id", required = false) String claimedUserId,
                           @RequestBody AmountRequest request) {
        return transactionService.withdraw(callerMatching(auth, claimedUserId), request.getAmount());
    }

    @PreAuthorize(CAN_TRANSACT)
    @PostMapping(value = "/transactions/transfer", consumes = "application/json")
    public Object transfer(Authentication auth,
                           @RequestHeader(value = "X-User-Id", required = false) String claimedUserId,
                           @RequestBody TransferRequest request) {
        return transactionService.transfer(callerMatching(auth, claimedUserId), request.getToUserId(),
                request.getAmount(), request.getReference());
    }

    @PreAuthorize(CAN_VIEW)
    @GetMapping("/balance/{userId}")
    public Object balance(Authentication auth, @PathVariable String userId) {
        String caller = callerMatching(auth, userId);
        return java.util.Map.of("userId", caller, "balance", transactionService.getBalance(caller));
    }

    @PreAuthorize(CAN_VIEW)
    @GetMapping("/transactions/{userId}")
    public Object transactions(Authentication auth, @PathVariable String userId) {
        return transactionService.getTransactions(callerMatching(auth, userId));
    }

    /** Returns the authenticated user ID, rejecting any caller-supplied ID that differs from it. */
    private static String callerMatching(Authentication auth, String claimedUserId) {
        String caller = auth.getName();
        if (claimedUserId != null && !claimedUserId.equals(caller)) {
            throw new AccessDeniedException("Requested account does not belong to the caller");
        }
        return caller;
    }
}
