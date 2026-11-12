/*
 * RecordCountKeyCodec.swift
 *
 * This source file is part of the FoundationDB open source project
 *
 * Copyright 2016-2025 Apple Inc. and the FoundationDB project authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if RecordLayer
import FoundationDB

/// Encodes the record count key stored in the header (`DataStoreInfo.record_count_key`).
///
/// This is Java's `KeyExpression` proto, so Java and Swift clients agree on whether counts must be
/// rebuilt. Field names come from the metadata's descriptors — attached, or reconstructed from
/// the generated message types. Only if neither is possible (e.g. a map field defeats
/// reconstruction) is a Swift-only encoding used, after which a Java client rebuilds the
/// counts once.
enum RecordCountKeyCodec {
    static func encode(_ node: KeyExpressionNode, metaData: RecordMetaData) -> FDB.Bytes {
        if let descriptors = try? metaData.effectiveDescriptorSet() {
            let names = metaData.recordTypes.compactMap {
                try? KeyExpressionProto.FieldNames(descriptorSet: descriptors, messageName: $0.recordName)
            }
            if names.count == metaData.recordTypes.count,
               let bytes = try? KeyExpressionProto.encodeForHeader(node, recordDescriptors: names) {
                return bytes
            }
        }
        return Array("swift:".utf8) + Array(String(describing: node).utf8)
    }
}
#endif
