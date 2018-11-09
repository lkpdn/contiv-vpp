// Copyright (c) 2018 Cisco and/or its affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at:
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package txn

import (
	"context"
	"fmt"

	"github.com/gogo/protobuf/proto"

	scheduler_api "github.com/ligato/vpp-agent/plugins/kvscheduler/api"
)

// kvSchedulerTxn implements Transaction interface for KVScheduler.
type kvSchedulerTxn struct {
	kvScheduler scheduler_api.KVScheduler
	values      KeyValuePairs
}

// lazyValue implements datasync.LazyValue interface.
type lazyValue struct {
	value proto.Message
}

// NewTransaction creates new transaction to be executed via KVScheduler.
func NewTransaction(kvScheduler scheduler_api.KVScheduler) Transaction {
	return &kvSchedulerTxn{
		kvScheduler: kvScheduler,
		values:      make(KeyValuePairs),
	}
}

// Commit applies the requested transaction changes.
func (txn *kvSchedulerTxn) Commit(ctx context.Context) error {
	schedTxn := txn.kvScheduler.StartNBTransaction()
	for key, value := range txn.values {
		schedTxn.SetValue(key, &lazyValue{value: value})
	}
	kvErrors, txnError := schedTxn.Commit(ctx)
	if txnError != nil || len(kvErrors) > 0 {
		return NewTransactionError(txnError, kvErrors)
	}
	return nil
}

// Put add request to the transaction to add or modify a value.
// <value> cannot be nil.
func (txn *kvSchedulerTxn) Put(key string, value proto.Message) {
	if value == nil {
		panic(fmt.Sprintf("Put nil value for key '%s'", key))
	}
	txn.values[key] = value
}

func (txn *kvSchedulerTxn) Delete(key string) {
	txn.values[key] = nil
}

// Get is used to obtain value already prepared to be applied by this transaction.
// Until the transaction is committed, provided values can still be changed.
func (txn *kvSchedulerTxn) Get(key string) proto.Message {
	value, _ := txn.values[key]
	return value
}

// GetValue places the value into the provided proto message.
func (lv *lazyValue) GetValue(value proto.Message) error {
	tmp, err := proto.Marshal(lv.value)
	if err != nil {
		return err
	}
	return proto.Unmarshal(tmp, value)
}