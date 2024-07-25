const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;

const log = std.log.scoped(.state_machine);
const tracer = @import("tracer.zig");

const stdx = @import("./stdx.zig");
const maybe = stdx.maybe;

const global_constants = @import("constants.zig");
const tb = @import("tigerbeetle.zig");
const vsr = @import("vsr.zig");
const snapshot_latest = @import("lsm/tree.zig").snapshot_latest;
const ScopeCloseMode = @import("lsm/tree.zig").ScopeCloseMode;
const WorkloadType = @import("state_machine/workload.zig").WorkloadType;
const GrooveType = @import("lsm/groove.zig").GrooveType;
const ForestType = @import("lsm/forest.zig").ForestType;
const ScanBuffer = @import("lsm/scan_buffer.zig").ScanBuffer;
const ScanLookupType = @import("lsm/scan_lookup.zig").ScanLookupType;

const Direction = @import("direction.zig").Direction;
const TimestampRange = @import("lsm/timestamp_range.zig").TimestampRange;

const RecordedEvent = tb.RecordedEvent;
const Account = tb.Account;
const AccountFlags = tb.AccountFlags;
const AccountBalance = tb.AccountBalance;

const Transfer = tb.Transfer;
const TransferFlags = tb.TransferFlags;
const TransferPendingStatus = tb.TransferPendingStatus;

const CreateAccountsResult = tb.CreateAccountsResult;
const CreateTransfersResult = tb.CreateTransfersResult;

const CreateAccountResult = tb.CreateAccountResult;
const CreateTransferResult = tb.CreateTransferResult;

const AppendStreamResult = tb.AppendStreamResult;
const ReadStreamResult = tb.ReadStreamResult;
const ReadAllResult = tb.ReadAllResult;

const AccountFilter = tb.AccountFilter;
const QueryFilter = tb.QueryFilter;

const ReadStreamFilter = tb.ReadStreamFilter;
const ReadAllFilter = tb.ReadAllFilter;

pub fn StateMachineType(
    comptime Storage: type,
    comptime config: global_constants.StateMachineConfig,
) type {
    assert(config.message_body_size_max > 0);
    assert(config.lsm_batch_multiple > 0);
    assert(config.vsr_operations_reserved > 0);

    return struct {
        const StateMachine = @This();
        const Grid = @import("vsr/grid.zig").GridType(Storage);

        pub const constants = struct {
            pub const message_body_size_max = config.message_body_size_max;

            /// The maximum number of objects within a batch, by operation.
            pub const batch_max = struct {
                pub const append_stream =
                    operation_batch_max(.append_stream, config.message_body_size_max);
                pub const read_stream =
                    operation_batch_max(.read_stream, config.message_body_size_max);
                pub const read_all =
                    operation_batch_max(.read_all, config.message_body_size_max);

                pub const create_accounts =
                    operation_batch_max(.create_accounts, config.message_body_size_max);
                pub const create_transfers =
                    operation_batch_max(.create_transfers, config.message_body_size_max);
                pub const lookup_accounts =
                    operation_batch_max(.lookup_accounts, config.message_body_size_max);
                pub const lookup_transfers =
                    operation_batch_max(.lookup_transfers, config.message_body_size_max);
                pub const get_account_transfers =
                    operation_batch_max(.get_account_transfers, config.message_body_size_max);
                pub const get_account_balances =
                    operation_batch_max(.get_account_balances, config.message_body_size_max);
                pub const query_accounts =
                    operation_batch_max(.query_accounts, config.message_body_size_max);
                pub const query_transfers =
                    operation_batch_max(.query_transfers, config.message_body_size_max);

                comptime {
                    assert(create_accounts > 0);
                    assert(create_transfers > 0);
                    assert(lookup_accounts > 0);
                    assert(lookup_transfers > 0);
                    assert(get_account_transfers > 0);
                    assert(get_account_balances > 0);
                    assert(query_accounts > 0);
                    assert(query_transfers > 0);
                    assert(append_stream > 0);
                    assert(read_stream > 0);
                    assert(read_all > 0);
                }
            };

            pub const tree_ids = struct {
                pub const events = .{
                    .id = 1,
                    .stream_id = 2,
                    .type = 3,
                    .data = 4,
                    .metadata = 5,
                    .timestamp = 6,
                    .sequence = 7,
                };

                pub const accounts = .{
                    .id = 1,
                    .user_data_128 = 2,
                    .user_data_64 = 3,
                    .user_data_32 = 4,
                    .ledger = 5,
                    .code = 6,
                    .timestamp = 7,
                };

                pub const transfers = .{
                    .id = 8,
                    .debit_account_id = 9,
                    .credit_account_id = 10,
                    .amount = 11,
                    .pending_id = 12,
                    .user_data_128 = 13,
                    .user_data_64 = 14,
                    .user_data_32 = 15,
                    .ledger = 16,
                    .code = 17,
                    .timestamp = 18,
                    .expires_at = 19,
                };

                pub const transfers_pending = .{
                    .timestamp = 20,
                    .status = 21,
                };

                pub const account_balances = .{
                    .timestamp = 22,
                };
            };
        };

        /// Used to determine if an operation can be batched at the VSR layer.
        /// If so, the StateMachine must support demuxing batched operations below.
        pub const batch_logical_allowed = std.enums.EnumArray(Operation, bool).init(.{
            .pulse = false,
            .create_accounts = true,
            .create_transfers = true,
            .append_stream = true,
            // Don't batch lookups/queries for now.
            .read_stream = false,
            .read_all = false,
            .lookup_accounts = false,
            .lookup_transfers = false,
            .get_account_transfers = false,
            .get_account_balances = false,
            .query_accounts = false,
            .query_transfers = false,
        });

        pub fn DemuxerType(comptime operation: Operation) type {
            assert(@bitSizeOf(Event(operation)) > 0);
            assert(@bitSizeOf(Result(operation)) > 0);

            return struct {
                const Demuxer = @This();
                const DemuxerResult = Result(operation);

                results: []DemuxerResult,

                /// Create a Demuxer which can extract Results out of the reply bytes in-place.
                /// Bytes must be aligned to hold Results (normally originating from message).
                pub fn init(reply: []u8) Demuxer {
                    return Demuxer{ .results = @alignCast(mem.bytesAsSlice(DemuxerResult, reply)) };
                }

                /// Returns a slice of bytes in the original reply with Results matching the Event
                /// range (offset and size). Each subsequent call to demux() must have ranges that
                /// are disjoint and increase monotonically.
                pub fn decode(self: *Demuxer, event_offset: u32, event_count: u32) []u8 {
                    const demuxed = blk: {
                        if (comptime batch_logical_allowed.get(operation)) {
                            // Count all results from out slice which match the Event range,
                            // updating the result.indexes to be related to the EVent in the
                            // process.
                            for (self.results, 0..) |*result, i| {
                                if (result.index < event_offset) break :blk i;
                                if (result.index >= event_offset + event_count) break :blk i;
                                result.index -= event_offset;
                            }
                        } else {
                            // Operations which aren't batched have the first Event consume the
                            // entire Result down below.
                            assert(event_offset == 0);
                        }
                        break :blk self.results.len;
                    };

                    // Return all results demuxed from the given Event, re-slicing them out of
                    // self.results to "consume" them from subsequent decode() calls.
                    defer self.results = self.results[demuxed..];
                    return mem.sliceAsBytes(self.results[0..demuxed]);
                }
            };
        }

        const batch_value_count_max = batch_value_counts_limit(config.message_body_size_max);

        const EventsGroove = GrooveType(
            Storage,
            RecordedEvent,
            .{
                .ids = constants.tree_ids.events,
                .batch_value_count_max = batch_value_count_max.events,
                .ignored = &[_][]const u8{},
                .derived = .{},
            },
        );

        const AccountsGroove = GrooveType(
            Storage,
            Account,
            .{
                .ids = constants.tree_ids.accounts,
                .batch_value_count_max = batch_value_count_max.accounts,
                .ignored = &[_][]const u8{
                    "debits_posted",
                    "debits_pending",
                    "credits_posted",
                    "credits_pending",
                    "flags",
                    "reserved",
                },
                .derived = .{},
            },
        );

        const TransfersGroove = GrooveType(
            Storage,
            Transfer,
            .{
                .ids = constants.tree_ids.transfers,
                .batch_value_count_max = batch_value_count_max.transfers,
                .ignored = &[_][]const u8{ "timeout", "flags" },
                .derived = .{
                    .expires_at = struct {
                        fn expires_at(object: *const Transfer) u64 {
                            if (object.flags.pending and object.timeout > 0) {
                                return object.timestamp + object.timeout_ns();
                            }
                            return 0;
                        }
                    }.expires_at,
                },
            },
        );

        const TransfersPendingGroove = GrooveType(
            Storage,
            TransferPending,
            .{
                .ids = constants.tree_ids.transfers_pending,
                .batch_value_count_max = batch_value_count_max.transfers_pending,
                .ignored = &[_][]const u8{"padding"},
                .derived = .{},
            },
        );

        pub const TransferPending = extern struct {
            timestamp: u64,
            status: TransferPendingStatus,
            padding: [7]u8 = [_]u8{0} ** 7,

            comptime {
                // Assert that there is no implicit padding.
                assert(@sizeOf(TransferPending) == 16);
                assert(stdx.no_padding(TransferPending));
            }
        };

        const AccountBalancesGroove = GrooveType(
            Storage,
            AccountBalancesGrooveValue,
            .{
                .ids = constants.tree_ids.account_balances,
                .batch_value_count_max = batch_value_count_max.account_balances,
                .ignored = &[_][]const u8{
                    "dr_account_id",
                    "dr_debits_pending",
                    "dr_debits_posted",
                    "dr_credits_pending",
                    "dr_credits_posted",
                    "cr_account_id",
                    "cr_debits_pending",
                    "cr_debits_posted",
                    "cr_credits_pending",
                    "cr_credits_posted",
                    "reserved",
                },
                .derived = .{},
            },
        );

        pub const AccountBalancesGrooveValue = extern struct {
            dr_account_id: u128,
            dr_debits_pending: u128,
            dr_debits_posted: u128,
            dr_credits_pending: u128,
            dr_credits_posted: u128,
            cr_account_id: u128,
            cr_debits_pending: u128,
            cr_debits_posted: u128,
            cr_credits_pending: u128,
            cr_credits_posted: u128,
            timestamp: u64 = 0,
            reserved: [88]u8 = [_]u8{0} ** 88,

            comptime {
                assert(stdx.no_padding(AccountBalancesGrooveValue));
                assert(@sizeOf(AccountBalancesGrooveValue) == 256);
                assert(@alignOf(AccountBalancesGrooveValue) == 16);
            }
        };

        pub const Workload = WorkloadType(StateMachine);

        pub const Forest = ForestType(Storage, .{
            .events = EventsGroove,
            .accounts = AccountsGroove,
            .transfers = TransfersGroove,
            .transfers_pending = TransfersPendingGroove,
            .account_balances = AccountBalancesGroove,
        });

        const EventsScanLookup = ScanLookupType(
            EventsGroove,
            EventsGroove.ScanBuilder.Scan,
            Storage,
        );

        const AccountsScanLookup = ScanLookupType(
            AccountsGroove,
            AccountsGroove.ScanBuilder.Scan,
            Storage,
        );

        const TransfersScanLookup = ScanLookupType(
            TransfersGroove,
            TransfersGroove.ScanBuilder.Scan,
            Storage,
        );

        const AccountBalancesScanLookup = ScanLookupType(
            AccountBalancesGroove,
            // Both Objects use the same timestamp, so we can use the TransfersGroove's indexes.
            TransfersGroove.ScanBuilder.Scan,
            Storage,
        );

        // Looking to make backwards incompatible changes here? Make sure to check release.zig for
        // `release_triple_client_min`.
        pub const Operation = enum(u8) {
            /// Operations exported by TigerBeetle:
            pulse = config.vsr_operations_reserved + 0,
            create_accounts = config.vsr_operations_reserved + 1,
            create_transfers = config.vsr_operations_reserved + 2,
            lookup_accounts = config.vsr_operations_reserved + 3,
            lookup_transfers = config.vsr_operations_reserved + 4,
            get_account_transfers = config.vsr_operations_reserved + 5,
            get_account_balances = config.vsr_operations_reserved + 6,
            query_accounts = config.vsr_operations_reserved + 7,
            query_transfers = config.vsr_operations_reserved + 8,
            // ...
            append_stream = config.vsr_operations_reserved + 9,
            read_stream = config.vsr_operations_reserved + 10,
            read_all = config.vsr_operations_reserved + 11,
        };

        pub fn operation_from_vsr(operation: vsr.Operation) ?Operation {
            if (operation == .pulse) return .pulse;
            if (operation.vsr_reserved()) return null;

            return vsr.Operation.to(StateMachine, operation);
        }

        pub const Options = struct {
            batch_size_limit: u32,
            lsm_forest_compaction_block_count: u32,
            lsm_forest_node_count: u32,
            cache_entries_accounts: u32,
            cache_entries_transfers: u32,
            cache_entries_posted: u32,
            cache_entries_account_balances: u32,
            cache_entries_events: u32,
        };

        /// Since prefetch contexts are used one at a time, it's safe to access
        /// the union's fields and reuse the same memory for all context instances.
        const PrefetchContext = union(enum) {
            null,
            accounts: AccountsGroove.PrefetchContext,
            transfers: TransfersGroove.PrefetchContext,
            transfers_pending: TransfersPendingGroove.PrefetchContext,

            pub const Field = std.meta.FieldEnum(PrefetchContext);
            pub fn FieldType(comptime field: Field) type {
                return std.meta.fieldInfo(PrefetchContext, field).type;
            }

            pub fn parent(
                comptime field: Field,
                completion: *FieldType(field),
            ) *StateMachine {
                comptime assert(field != .null);

                const context: *PrefetchContext = @fieldParentPtr(@tagName(field), completion);
                return @fieldParentPtr("prefetch_context", context);
            }

            pub fn get(self: *PrefetchContext, comptime field: Field) *FieldType(field) {
                comptime assert(field != .null);
                assert(self.* == .null);

                self.* = @unionInit(PrefetchContext, @tagName(field), undefined);
                return &@field(self, @tagName(field));
            }
        };

        const ExpirePendingTransfers = ExpirePendingTransfersType(TransfersGroove, Storage);

        /// Since scan lookups are used one at a time, it's safe to access
        /// the union's fields and reuse the same memory for all ScanLookup instances.
        const ScanLookup = union(enum) {
            null,
            transfers: TransfersScanLookup,
            accounts: AccountsScanLookup,
            account_balances: AccountBalancesScanLookup,
            expire_pending_transfers: ExpirePendingTransfers.ScanLookup,

            pub const Field = std.meta.FieldEnum(ScanLookup);
            pub fn FieldType(comptime field: Field) type {
                return std.meta.fieldInfo(ScanLookup, field).type;
            }

            pub fn parent(
                comptime field: Field,
                completion: *FieldType(field),
            ) *StateMachine {
                comptime assert(field != .null);

                const context: *ScanLookup = @fieldParentPtr(@tagName(field), completion);
                return @fieldParentPtr("scan_lookup", context);
            }

            pub fn get(self: *ScanLookup, comptime field: Field) *FieldType(field) {
                comptime assert(field != .null);
                assert(self.* == .null);

                self.* = @unionInit(ScanLookup, @tagName(field), undefined);
                return &@field(self, @tagName(field));
            }
        };

        batch_size_limit: u32,
        prefetch_timestamp: u64,
        prepare_timestamp: u64,
        commit_timestamp: u64,
        forest: Forest,

        prefetch_input: ?[]align(16) const u8 = null,
        prefetch_callback: ?*const fn (*StateMachine) void = null,
        prefetch_context: PrefetchContext = .null,

        scan_lookup: ScanLookup = .null,
        scan_lookup_buffer: []align(16) u8,
        scan_lookup_result_count: ?u32 = null,
        scan_lookup_next_tick: Grid.NextTick = undefined,

        expire_pending_transfers: ExpirePendingTransfers = .{},

        open_callback: ?*const fn (*StateMachine) void = null,
        compact_callback: ?*const fn (*StateMachine) void = null,
        checkpoint_callback: ?*const fn (*StateMachine) void = null,

        tracer_slot: ?tracer.SpanStart = null,

        pub fn init(allocator: mem.Allocator, grid: *Grid, options: Options) !StateMachine {
            assert(options.batch_size_limit <= config.message_body_size_max);
            inline for (comptime std.enums.values(Operation)) |operation| {
                assert(options.batch_size_limit >= @sizeOf(Event(operation)));
            }

            var forest = try Forest.init(
                allocator,
                grid,
                .{
                    .compaction_block_count = options.lsm_forest_compaction_block_count,
                    .node_count = options.lsm_forest_node_count,
                },
                forest_options(options),
            );
            errdefer forest.deinit(allocator);

            const scan_lookup_buffer = try allocator.alignedAlloc(u8, 16, @max(
                constants.batch_max.get_account_transfers * @sizeOf(Transfer),
                constants.batch_max.get_account_balances * @sizeOf(AccountBalancesGrooveValue),
            ));

            return StateMachine{
                .batch_size_limit = options.batch_size_limit,
                .prefetch_timestamp = 0,
                .prepare_timestamp = 0,
                .commit_timestamp = 0,
                .forest = forest,
                .scan_lookup_buffer = scan_lookup_buffer,
            };
        }

        pub fn deinit(self: *StateMachine, allocator: mem.Allocator) void {
            assert(self.tracer_slot == null);

            allocator.free(self.scan_lookup_buffer);
            self.forest.deinit(allocator);
        }

        // TODO Reset here and in LSM should clean up (i.e. end) tracer spans.
        // tracer.end() requires an event be passed in. We will need an additional tracer.end
        // function that doesn't require the explicit event be passed in. The Trace should store the
        // event so that it knows what event should be ending during reset() (and deinit(), maybe).
        // Then the original tracer.end() can assert that the two events match.
        pub fn reset(self: *StateMachine) void {
            self.forest.reset();

            self.* = .{
                .batch_size_limit = self.batch_size_limit,
                .prefetch_timestamp = 0,
                .prepare_timestamp = 0,
                .commit_timestamp = 0,
                .forest = self.forest,
                .scan_lookup_buffer = self.scan_lookup_buffer,
            };
        }

        pub fn Event(comptime operation: Operation) type {
            return switch (operation) {
                .pulse => void,
                .create_accounts => Account,
                .create_transfers => Transfer,
                .lookup_accounts => u128,
                .lookup_transfers => u128,
                .get_account_transfers => AccountFilter,
                .get_account_balances => AccountFilter,
                .query_accounts => QueryFilter,
                .query_transfers => QueryFilter,
                .append_stream => Event,
                .read_stream => ReadStreamFilter,
                .read_all => ReadAllFilter,
            };
        }

        pub fn Result(comptime operation: Operation) type {
            return switch (operation) {
                .pulse => void,
                .create_accounts => CreateAccountsResult,
                .create_transfers => CreateTransfersResult,
                .lookup_accounts => Account,
                .lookup_transfers => Transfer,
                .get_account_transfers => Transfer,
                .get_account_balances => AccountBalance,
                .query_accounts => Account,
                .query_transfers => Transfer,
                .append_stream => AppendStreamResult,
                .read_stream => ReadStreamResult,
                .read_all => ReadAllResult,
            };
        }

        pub fn open(self: *StateMachine, callback: *const fn (*StateMachine) void) void {
            assert(self.open_callback == null);
            self.open_callback = callback;

            self.forest.open(forest_open_callback);
        }

        fn forest_open_callback(forest: *Forest) void {
            const self: *StateMachine = @fieldParentPtr("forest", forest);
            assert(self.open_callback != null);

            const callback = self.open_callback.?;
            self.open_callback = null;
            callback(self);
        }

        pub fn input_valid(
            self: *const StateMachine,
            operation: Operation,
            input: []align(16) const u8,
        ) bool {
            assert(input.len <= self.batch_size_limit);

            switch (operation) {
                .pulse => {
                    if (input.len != 0) return false;
                },
                inline .get_account_transfers,
                .get_account_balances,
                .query_accounts,
                .query_transfers,
                => |comptime_operation| {
                    const event_size = @sizeOf(Event(comptime_operation));

                    if (input.len != event_size) return false;
                },
                inline else => |comptime_operation| {
                    const event_size = @sizeOf(Event(comptime_operation));
                    comptime assert(event_size > 0);

                    const batch_limit: u32 =
                        operation_batch_max(comptime_operation, self.batch_size_limit);
                    assert(batch_limit > 0);

                    // Clients do not validate batch size == 0,
                    // and even the simulator can generate requests with no events.
                    maybe(input.len == 0);

                    if (input.len % event_size != 0) return false;
                    if (input.len > batch_limit * event_size) return false;
                },
            }

            return true;
        }

        /// Updates `prepare_timestamp` to the highest timestamp of the response.
        pub fn prepare(
            self: *StateMachine,
            operation: Operation,
            input: []align(16) const u8,
        ) void {
            assert(self.input_valid(operation, input));
            assert(input.len <= self.batch_size_limit);

            self.prepare_timestamp += switch (operation) {
                .pulse => 0,
                .create_accounts => mem.bytesAsSlice(Account, input).len,
                .create_transfers => mem.bytesAsSlice(Transfer, input).len,
                .lookup_accounts => 0,
                .lookup_transfers => 0,
                .get_account_transfers => 0,
                .get_account_balances => 0,
                .query_accounts => 0,
                .query_transfers => 0,
            };
        }

        pub fn pulse_needed(self: *const StateMachine, timestamp: u64) bool {
            assert(!global_constants.aof_recovery);
            assert(self.expire_pending_transfers.pulse_next_timestamp >=
                TimestampRange.timestamp_min);

            return self.expire_pending_transfers.pulse_next_timestamp <= timestamp;
        }

        pub fn prefetch(
            self: *StateMachine,
            callback: *const fn (*StateMachine) void,
            op: u64,
            operation: Operation,
            input: []align(16) const u8,
        ) void {
            _ = op;
            assert(self.prefetch_input == null);
            assert(self.prefetch_callback == null);
            assert(self.input_valid(operation, input));
            assert(input.len <= self.batch_size_limit);

            tracer.start(
                &self.tracer_slot,
                .state_machine_prefetch,
                @src(),
            );

            self.prefetch_input = input;
            self.prefetch_callback = callback;

            // TODO(Snapshots) Pass in the target snapshot.
            self.forest.grooves.accounts.prefetch_setup(null);
            self.forest.grooves.transfers.prefetch_setup(null);
            self.forest.grooves.transfers_pending.prefetch_setup(null);

            return switch (operation) {
                .pulse => {
                    assert(input.len == 0);
                    self.prefetch_expire_pending_transfers();
                },
                .create_accounts => {
                    self.prefetch_create_accounts(mem.bytesAsSlice(Account, input));
                },
                .create_transfers => {
                    self.prefetch_create_transfers(mem.bytesAsSlice(Transfer, input));
                },
                .lookup_accounts => {
                    self.prefetch_lookup_accounts(mem.bytesAsSlice(u128, input));
                },
                .lookup_transfers => {
                    self.prefetch_lookup_transfers(mem.bytesAsSlice(u128, input));
                },
                .get_account_transfers => {
                    self.prefetch_get_account_transfers(parse_filter_from_input(input));
                },
                .get_account_balances => {
                    self.prefetch_get_account_balances(parse_filter_from_input(input));
                },
                .query_accounts => {
                    self.prefetch_query_accounts(mem.bytesToValue(QueryFilter, input));
                },
                .query_transfers => {
                    self.prefetch_query_transfers(mem.bytesToValue(QueryFilter, input));
                },
            };
        }

        fn prefetch_finish(self: *StateMachine) void {
            assert(self.prefetch_input != null);
            assert(self.prefetch_context == .null);
            assert(self.scan_lookup == .null);

            const callback = self.prefetch_callback.?;
            self.prefetch_input = null;
            self.prefetch_callback = null;

            tracer.end(
                &self.tracer_slot,
                .state_machine_prefetch,
            );

            callback(self);
        }

        fn prefetch_create_accounts(self: *StateMachine, accounts: []const Account) void {
            for (accounts) |*a| {
                self.forest.grooves.accounts.prefetch_enqueue(a.id);
            }

            self.forest.grooves.accounts.prefetch(
                prefetch_create_accounts_callback,
                self.prefetch_context.get(.accounts),
            );
        }

        fn prefetch_create_accounts_callback(
            completion: *AccountsGroove.PrefetchContext,
        ) void {
            const self: *StateMachine = PrefetchContext.parent(.accounts, completion);
            self.prefetch_context = .null;

            self.prefetch_finish();
        }

        fn prefetch_create_transfers(self: *StateMachine, transfers: []const Transfer) void {
            for (transfers) |*t| {
                self.forest.grooves.transfers.prefetch_enqueue(t.id);

                if (t.flags.post_pending_transfer or t.flags.void_pending_transfer) {
                    self.forest.grooves.transfers.prefetch_enqueue(t.pending_id);
                }
            }

            self.forest.grooves.transfers.prefetch(
                prefetch_create_transfers_callback_transfers,
                self.prefetch_context.get(.transfers),
            );
        }

        fn prefetch_create_transfers_callback_transfers(
            completion: *TransfersGroove.PrefetchContext,
        ) void {
            const self: *StateMachine = PrefetchContext.parent(.transfers, completion);
            self.prefetch_context = .null;

            const transfers = mem.bytesAsSlice(Event(.create_transfers), self.prefetch_input.?);
            for (transfers) |*t| {
                if (t.flags.post_pending_transfer or t.flags.void_pending_transfer) {
                    if (self.forest.grooves.transfers.get(t.pending_id)) |p| {
                        // This prefetch isn't run yet, but enqueue it here as well to save an extra
                        // iteration over transfers.
                        self.forest.grooves.transfers_pending.prefetch_enqueue(p.timestamp);

                        self.forest.grooves.accounts.prefetch_enqueue(p.debit_account_id);
                        self.forest.grooves.accounts.prefetch_enqueue(p.credit_account_id);
                    }
                } else {
                    self.forest.grooves.accounts.prefetch_enqueue(t.debit_account_id);
                    self.forest.grooves.accounts.prefetch_enqueue(t.credit_account_id);
                }
            }

            self.forest.grooves.accounts.prefetch(
                prefetch_create_transfers_callback_accounts,
                self.prefetch_context.get(.accounts),
            );
        }

        fn prefetch_create_transfers_callback_accounts(
            completion: *AccountsGroove.PrefetchContext,
        ) void {
            const self: *StateMachine = PrefetchContext.parent(.accounts, completion);
            self.prefetch_context = .null;

            self.forest.grooves.transfers_pending.prefetch(
                prefetch_create_transfers_callback_transfers_pending,
                self.prefetch_context.get(.transfers_pending),
            );
        }

        fn prefetch_create_transfers_callback_transfers_pending(
            completion: *TransfersPendingGroove.PrefetchContext,
        ) void {
            const self: *StateMachine = PrefetchContext.parent(.transfers_pending, completion);
            self.prefetch_context = .null;

            self.prefetch_finish();
        }

        fn prefetch_lookup_accounts(self: *StateMachine, ids: []const u128) void {
            for (ids) |id| {
                self.forest.grooves.accounts.prefetch_enqueue(id);
            }

            self.forest.grooves.accounts.prefetch(
                prefetch_lookup_accounts_callback,
                self.prefetch_context.get(.accounts),
            );
        }

        fn prefetch_lookup_accounts_callback(completion: *AccountsGroove.PrefetchContext) void {
            const self: *StateMachine = PrefetchContext.parent(.accounts, completion);
            self.prefetch_context = .null;

            self.prefetch_finish();
        }

        fn prefetch_lookup_transfers(self: *StateMachine, ids: []const u128) void {
            for (ids) |id| {
                self.forest.grooves.transfers.prefetch_enqueue(id);
            }

            self.forest.grooves.transfers.prefetch(
                prefetch_lookup_transfers_callback,
                self.prefetch_context.get(.transfers),
            );
        }

        fn prefetch_lookup_transfers_callback(completion: *TransfersGroove.PrefetchContext) void {
            const self: *StateMachine = PrefetchContext.parent(.transfers, completion);
            self.prefetch_context = .null;

            self.prefetch_finish();
        }

        fn prefetch_get_account_transfers(self: *StateMachine, filter: AccountFilter) void {
            assert(self.scan_lookup_result_count == null);
            assert(self.forest.scan_buffer_pool.scan_buffer_used == 0);

            if (self.get_scan_from_account_filter(filter)) |scan| {
                assert(self.forest.scan_buffer_pool.scan_buffer_used > 0);

                var scan_buffer = std.mem.bytesAsSlice(
                    Transfer,
                    self.scan_lookup_buffer[0 .. @sizeOf(Transfer) *
                        constants.batch_max.get_account_transfers],
                );
                assert(scan_buffer.len <= constants.batch_max.get_account_transfers);

                var scan_lookup = self.scan_lookup.get(.transfers);
                scan_lookup.* = TransfersScanLookup.init(
                    &self.forest.grooves.transfers,
                    scan,
                );

                scan_lookup.read(
                    // Limiting the buffer size according to the query limit.
                    scan_buffer[0..@min(filter.limit, scan_buffer.len)],
                    &prefetch_get_account_transfers_callback,
                );

                return;
            }

            // TODO(batiati): Improve the way we do validations on the state machine.
            log.info("invalid filter for get_account_transfers: {any}", .{filter});
            self.forest.grid.on_next_tick(
                &prefetch_scan_next_tick_callback,
                &self.scan_lookup_next_tick,
            );
        }

        fn prefetch_get_account_transfers_callback(
            scan_lookup: *TransfersScanLookup,
            results: []const Transfer,
        ) void {
            const self: *StateMachine = ScanLookup.parent(.transfers, scan_lookup);
            assert(self.scan_lookup_result_count == null);
            self.scan_lookup_result_count = @intCast(results.len);

            self.scan_lookup = .null;
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.transfers.scan_builder.reset();

            self.prefetch_finish();
        }

        fn prefetch_get_account_balances(self: *StateMachine, filter: AccountFilter) void {
            assert(self.scan_lookup_result_count == null);

            self.forest.grooves.accounts.prefetch_enqueue(filter.account_id);
            self.forest.grooves.accounts.prefetch(
                prefetch_get_account_balances_lookup_account_callback,
                self.prefetch_context.get(.accounts),
            );
        }

        fn prefetch_get_account_balances_lookup_account_callback(
            completion: *AccountsGroove.PrefetchContext,
        ) void {
            const self: *StateMachine = PrefetchContext.parent(.accounts, completion);
            self.prefetch_context = .null;

            const filter = parse_filter_from_input(self.prefetch_input.?);
            self.prefetch_get_account_balances_scan(filter);
        }

        fn prefetch_get_account_balances_scan(self: *StateMachine, filter: AccountFilter) void {
            assert(self.scan_lookup_result_count == null);
            assert(self.forest.scan_buffer_pool.scan_buffer_used == 0);

            if (self.forest.grooves.accounts.get(filter.account_id)) |account| {
                if (account.flags.history) {
                    if (self.get_scan_from_account_filter(filter)) |scan| {
                        assert(self.forest.scan_buffer_pool.scan_buffer_used > 0);

                        var scan_lookup_buffer = std.mem.bytesAsSlice(
                            AccountBalancesGrooveValue,
                            self.scan_lookup_buffer[0 .. @sizeOf(AccountBalancesGrooveValue) *
                                constants.batch_max.get_account_balances],
                        );

                        var scan_lookup = self.scan_lookup.get(.account_balances);
                        scan_lookup.* = AccountBalancesScanLookup.init(
                            &self.forest.grooves.account_balances,
                            scan,
                        );

                        scan_lookup.read(
                            // Limiting the buffer size according to the query limit.
                            scan_lookup_buffer[0..@min(filter.limit, scan_lookup_buffer.len)],
                            &prefetch_get_account_balances_scan_callback,
                        );

                        return;
                    }
                }
            }

            // TODO(batiati): Improve the way we do validations on the state machine.
            log.info(
                "invalid filter for get_account_balances: {any}",
                .{filter},
            );

            // Returning an empty array on the next tick.
            self.forest.grid.on_next_tick(
                &prefetch_scan_next_tick_callback,
                &self.scan_lookup_next_tick,
            );
        }

        fn prefetch_get_account_balances_scan_callback(
            scan_lookup: *AccountBalancesScanLookup,
            results: []const AccountBalancesGrooveValue,
        ) void {
            const self: *StateMachine = ScanLookup.parent(.account_balances, scan_lookup);
            assert(self.scan_lookup_result_count == null);
            self.scan_lookup_result_count = @intCast(results.len);

            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.transfers.scan_builder.reset();
            self.scan_lookup = .null;

            self.prefetch_finish();
        }

        // TODO(batiati): Using a zeroed filter in case of invalid input.
        // Implement input validation on `prepare` for all operations.
        fn parse_filter_from_input(input: []const u8) AccountFilter {
            return if (input.len != @sizeOf(AccountFilter))
                std.mem.zeroInit(AccountFilter, .{})
            else
                mem.bytesToValue(
                    AccountFilter,
                    input[0..@sizeOf(AccountFilter)],
                );
        }

        fn get_scan_from_account_filter(
            self: *StateMachine,
            filter: AccountFilter,
        ) ?*TransfersGroove.ScanBuilder.Scan {
            assert(self.forest.scan_buffer_pool.scan_buffer_used == 0);

            const filter_valid =
                filter.account_id != 0 and filter.account_id != std.math.maxInt(u128) and
                filter.timestamp_min != std.math.maxInt(u64) and
                filter.timestamp_max != std.math.maxInt(u64) and
                (filter.timestamp_max == 0 or filter.timestamp_min <= filter.timestamp_max) and
                filter.limit != 0 and
                (filter.flags.credits or filter.flags.debits) and
                filter.flags.padding == 0 and
                stdx.zeroed(&filter.reserved);

            if (!filter_valid) return null;

            const transfers_groove: *TransfersGroove = &self.forest.grooves.transfers;
            const scan_builder: *TransfersGroove.ScanBuilder = &transfers_groove.scan_builder;

            const timestamp_range: TimestampRange = .{
                .min = if (filter.timestamp_min == 0)
                    TimestampRange.timestamp_min
                else
                    filter.timestamp_min,

                .max = if (filter.timestamp_max == 0)
                    TimestampRange.timestamp_max
                else
                    filter.timestamp_max,
            };
            assert(timestamp_range.min <= timestamp_range.max);

            // This query may have 2 conditions:
            // `WHERE debit_account_id = $account_id OR credit_account_id = $account_id`.
            var scan_conditions: stdx.BoundedArray(*TransfersGroove.ScanBuilder.Scan, 2) = .{};
            const direction: Direction = if (filter.flags.reversed) .descending else .ascending;

            // Adding the condition for `debit_account_id = $account_id`.
            if (filter.flags.debits) {
                scan_conditions.append_assume_capacity(scan_builder.scan_prefix(
                    .debit_account_id,
                    self.forest.scan_buffer_pool.acquire_assume_capacity(),
                    snapshot_latest,
                    filter.account_id,
                    timestamp_range,
                    direction,
                ));
            }

            // Adding the condition for `credit_account_id = $account_id`.
            if (filter.flags.credits) {
                scan_conditions.append_assume_capacity(scan_builder.scan_prefix(
                    .credit_account_id,
                    self.forest.scan_buffer_pool.acquire_assume_capacity(),
                    snapshot_latest,
                    filter.account_id,
                    timestamp_range,
                    direction,
                ));
            }

            return switch (scan_conditions.count()) {
                1 => scan_conditions.get(0),
                // Creating an union `OR` with the conditions.
                2 => scan_builder.merge_union(scan_conditions.const_slice()),
                else => unreachable,
            };
        }

        fn prefetch_scan_next_tick_callback(completion: *Grid.NextTick) void {
            const self: *StateMachine = @alignCast(@fieldParentPtr(
                "scan_lookup_next_tick",
                completion,
            ));
            assert(self.forest.scan_buffer_pool.scan_buffer_used == 0);
            assert(self.scan_lookup == .null);

            self.prefetch_finish();
        }

        fn prefetch_query_accounts(self: *StateMachine, filter: QueryFilter) void {
            assert(self.scan_lookup_result_count == null);

            if (self.get_scan_from_query_filter(
                AccountsGroove,
                &self.forest.grooves.accounts,
                filter,
            )) |scan| {
                assert(self.forest.scan_buffer_pool.scan_buffer_used > 0);

                const scan_buffer = std.mem.bytesAsSlice(
                    Account,
                    self.scan_lookup_buffer[0 .. @sizeOf(Account) *
                        constants.batch_max.query_accounts],
                );
                assert(scan_buffer.len <= constants.batch_max.query_accounts);

                const scan_lookup = self.scan_lookup.get(.accounts);
                scan_lookup.* = AccountsScanLookup.init(
                    &self.forest.grooves.accounts,
                    scan,
                );

                scan_lookup.read(
                    // Limiting the buffer size according to the query limit.
                    scan_buffer[0..@min(filter.limit, scan_buffer.len)],
                    &prefetch_query_accounts_callback,
                );
                return;
            }

            // TODO(batiati): Improve the way we do validations on the state machine.
            log.info("invalid filter for query_accounts: {any}", .{filter});
            self.forest.grid.on_next_tick(
                &prefetch_scan_next_tick_callback,
                &self.scan_lookup_next_tick,
            );
        }

        fn prefetch_query_accounts_callback(
            scan_lookup: *AccountsScanLookup,
            results: []const Account,
        ) void {
            const self: *StateMachine = ScanLookup.parent(.accounts, scan_lookup);
            assert(self.scan_lookup_result_count == null);
            self.scan_lookup_result_count = @intCast(results.len);

            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.accounts.scan_builder.reset();
            self.scan_lookup = .null;

            self.prefetch_finish();
        }

        fn prefetch_query_transfers(self: *StateMachine, filter: QueryFilter) void {
            assert(self.scan_lookup_result_count == null);

            if (self.get_scan_from_query_filter(
                TransfersGroove,
                &self.forest.grooves.transfers,
                filter,
            )) |scan| {
                assert(self.forest.scan_buffer_pool.scan_buffer_used > 0);

                var scan_buffer = std.mem.bytesAsSlice(
                    Transfer,
                    self.scan_lookup_buffer[0 .. @sizeOf(Transfer) *
                        constants.batch_max.query_transfers],
                );
                assert(scan_buffer.len <= constants.batch_max.query_transfers);

                var scan_lookup = self.scan_lookup.get(.transfers);
                scan_lookup.* = TransfersScanLookup.init(
                    &self.forest.grooves.transfers,
                    scan,
                );

                scan_lookup.read(
                    // Limiting the buffer size according to the query limit.
                    scan_buffer[0..@min(filter.limit, scan_buffer.len)],
                    &prefetch_query_transfers_callback,
                );
                return;
            }

            // TODO(batiati): Improve the way we do validations on the state machine.
            log.info("invalid filter for query_transfers: {any}", .{filter});
            self.forest.grid.on_next_tick(
                &prefetch_scan_next_tick_callback,
                &self.scan_lookup_next_tick,
            );
        }

        fn prefetch_query_transfers_callback(
            scan_lookup: *TransfersScanLookup,
            results: []const Transfer,
        ) void {
            const self: *StateMachine = ScanLookup.parent(.transfers, scan_lookup);
            assert(self.scan_lookup_result_count == null);
            self.scan_lookup_result_count = @intCast(results.len);

            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.transfers.scan_builder.reset();
            self.scan_lookup = .null;

            self.prefetch_finish();
        }

        fn get_scan_from_query_filter(
            self: *StateMachine,
            comptime Groove: type,
            groove: *Groove,
            filter: QueryFilter,
        ) ?*Groove.ScanBuilder.Scan {
            assert(self.forest.scan_buffer_pool.scan_buffer_used == 0);

            const filter_valid =
                filter.timestamp_min != std.math.maxInt(u64) and
                filter.timestamp_max != std.math.maxInt(u64) and
                (filter.timestamp_max == 0 or filter.timestamp_min <= filter.timestamp_max) and
                filter.limit != 0 and
                filter.flags.padding == 0 and
                stdx.zeroed(&filter.reserved);

            if (!filter_valid) return null;

            const direction: Direction = if (filter.flags.reversed) .descending else .ascending;
            const timestamp_range: TimestampRange = .{
                .min = if (filter.timestamp_min == 0)
                    TimestampRange.timestamp_min
                else
                    filter.timestamp_min,

                .max = if (filter.timestamp_max == 0)
                    TimestampRange.timestamp_max
                else
                    filter.timestamp_max,
            };
            assert(timestamp_range.min <= timestamp_range.max);

            const indexes = [_]std.meta.FieldEnum(QueryFilter){
                .user_data_128,
                .user_data_64,
                .user_data_32,
                .ledger,
                .code,
            };
            comptime assert(indexes.len <= global_constants.lsm_scans_max);

            var scan_conditions: stdx.BoundedArray(*Groove.ScanBuilder.Scan, indexes.len) = .{};
            inline for (indexes) |index| {
                if (@field(filter, @tagName(index)) != 0) {
                    scan_conditions.append_assume_capacity(groove.scan_builder.scan_prefix(
                        std.enums.nameCast(std.meta.FieldEnum(Groove.IndexTrees), index),
                        self.forest.scan_buffer_pool.acquire_assume_capacity(),
                        snapshot_latest,
                        @field(filter, @tagName(index)),
                        timestamp_range,
                        direction,
                    ));
                }
            }

            return switch (scan_conditions.count()) {
                0 =>
                // TODO(batiati): Querying only by timestamp uses the Object groove,
                // we could skip the lookup step entirely then.
                // It will be implemented as part of the query executor.
                groove.scan_builder.scan_timestamp(
                    self.forest.scan_buffer_pool.acquire_assume_capacity(),
                    snapshot_latest,
                    timestamp_range,
                    direction,
                ),
                1 => scan_conditions.get(0),
                else => groove.scan_builder.merge_intersection(scan_conditions.const_slice()),
            };
        }

        fn prefetch_expire_pending_transfers(self: *StateMachine) void {
            assert(self.scan_lookup_result_count == null);
            assert(self.forest.scan_buffer_pool.scan_buffer_used == 0);
            assert(self.prefetch_timestamp >= TimestampRange.timestamp_min);
            assert(self.prefetch_timestamp <= TimestampRange.timestamp_max);

            // We must be constrained to the same limit as `create_transfers`.
            const scan_buffer_size = @divFloor(
                self.batch_size_limit,
                @sizeOf(Transfer),
            ) * @sizeOf(Transfer);

            const scan_lookup_buffer = std.mem.bytesAsSlice(
                Transfer,
                self.scan_lookup_buffer[0..scan_buffer_size],
            );

            const transfers_groove: *TransfersGroove = &self.forest.grooves.transfers;
            const scan = self.expire_pending_transfers.scan(
                &transfers_groove.indexes.expires_at,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                .{
                    .snapshot = transfers_groove.prefetch_snapshot.?,
                    .expires_at_max = self.prefetch_timestamp,
                },
            );

            const scan_lookup = self.scan_lookup.get(.expire_pending_transfers);
            scan_lookup.* = ExpirePendingTransfers.ScanLookup.init(
                transfers_groove,
                scan,
            );
            scan_lookup.read(
                scan_lookup_buffer,
                &prefetch_expire_pending_transfers_scan_callback,
            );
        }

        fn prefetch_expire_pending_transfers_scan_callback(
            scan_lookup: *ExpirePendingTransfers.ScanLookup,
            results: []const Transfer,
        ) void {
            const self: *StateMachine = ScanLookup.parent(.expire_pending_transfers, scan_lookup);
            assert(self.scan_lookup_result_count == null);

            self.expire_pending_transfers.finish(scan_lookup.state, results);
            self.scan_lookup_result_count = @intCast(results.len);

            self.scan_lookup = .null;
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.transfers.scan_builder.reset();

            self.prefetch_expire_pending_transfers_accounts();
        }

        fn prefetch_expire_pending_transfers_accounts(self: *StateMachine) void {
            const transfers: []const Transfer = std.mem.bytesAsSlice(
                Transfer,
                self.scan_lookup_buffer[0 .. self.scan_lookup_result_count.? * @sizeOf(Transfer)],
            );

            const grooves = &self.forest.grooves;
            for (transfers) |expired| {
                assert(expired.flags.pending == true);
                const expires_at = expired.timestamp + expired.timeout_ns();

                assert(expires_at <= self.prefetch_timestamp);

                grooves.accounts.prefetch_enqueue(expired.debit_account_id);
                grooves.accounts.prefetch_enqueue(expired.credit_account_id);
                grooves.transfers_pending.prefetch_enqueue(expired.timestamp);
            }

            self.forest.grooves.accounts.prefetch(
                prefetch_expire_pending_transfers_callback_accounts,
                self.prefetch_context.get(.accounts),
            );
        }

        fn prefetch_expire_pending_transfers_callback_accounts(
            completion: *AccountsGroove.PrefetchContext,
        ) void {
            const self: *StateMachine = PrefetchContext.parent(.accounts, completion);
            self.prefetch_context = .null;

            self.forest.grooves.transfers_pending.prefetch(
                prefetch_expire_pending_transfers_callback_transfers_pending,
                self.prefetch_context.get(.transfers_pending),
            );
        }

        fn prefetch_expire_pending_transfers_callback_transfers_pending(
            completion: *TransfersPendingGroove.PrefetchContext,
        ) void {
            const self: *StateMachine = PrefetchContext.parent(.transfers_pending, completion);
            self.prefetch_context = .null;

            self.prefetch_finish();
        }

        pub fn commit(
            self: *StateMachine,
            client: u128,
            op: u64,
            timestamp: u64,
            operation: Operation,
            input: []align(16) const u8,
            output: *align(16) [constants.message_body_size_max]u8,
        ) usize {
            _ = client;
            assert(op != 0);
            assert(self.input_valid(operation, input));
            assert(timestamp > self.commit_timestamp or global_constants.aof_recovery);
            assert(input.len <= self.batch_size_limit);

            maybe(self.scan_lookup_result_count != null);
            defer assert(self.scan_lookup_result_count == null);

            tracer.start(
                &self.tracer_slot,
                .state_machine_commit,
                @src(),
            );

            const result = switch (operation) {
                .pulse => self.execute_expire_pending_transfers(timestamp),
                .create_accounts => self.execute(.create_accounts, timestamp, input, output),
                .create_transfers => self.execute(.create_transfers, timestamp, input, output),
                .lookup_accounts => self.execute_lookup_accounts(input, output),
                .lookup_transfers => self.execute_lookup_transfers(input, output),
                .get_account_transfers => self.execute_get_account_transfers(input, output),
                .get_account_balances => self.execute_get_account_balances(input, output),
                .query_accounts => self.execute_query_accounts(input, output),
                .query_transfers => self.execute_query_transfers(input, output),

                .append_stream => self.execute_append_stream(timestamp, input, output),
                .read_stream => self.execute_read_stream(input, output),
                .read_all => self.execute_read_all(output),
            };

            tracer.end(
                &self.tracer_slot,
                .state_machine_commit,
            );

            return result;
        }

        pub fn compact(
            self: *StateMachine,
            callback: *const fn (*StateMachine) void,
            op: u64,
        ) void {
            assert(self.compact_callback == null);
            assert(self.checkpoint_callback == null);

            tracer.start(
                &self.tracer_slot,
                .state_machine_compact,
                @src(),
            );

            self.compact_callback = callback;
            self.forest.compact(compact_finish, op);
        }

        fn compact_finish(forest: *Forest) void {
            const self: *StateMachine = @fieldParentPtr("forest", forest);
            const callback = self.compact_callback.?;
            self.compact_callback = null;

            tracer.end(
                &self.tracer_slot,
                .state_machine_compact,
            );

            callback(self);
        }

        pub fn checkpoint(self: *StateMachine, callback: *const fn (*StateMachine) void) void {
            assert(self.compact_callback == null);
            assert(self.checkpoint_callback == null);

            self.checkpoint_callback = callback;
            self.forest.checkpoint(checkpoint_finish);
        }

        fn checkpoint_finish(forest: *Forest) void {
            const self: *StateMachine = @fieldParentPtr("forest", forest);
            const callback = self.checkpoint_callback.?;
            self.checkpoint_callback = null;
            callback(self);
        }

        fn scope_open(self: *StateMachine, operation: Operation) void {
            switch (operation) {
                .create_accounts => {
                    self.forest.grooves.accounts.scope_open();
                },
                .create_transfers => {
                    self.forest.grooves.accounts.scope_open();
                    self.forest.grooves.transfers.scope_open();
                    self.forest.grooves.transfers_pending.scope_open();
                    self.forest.grooves.account_balances.scope_open();
                },
                else => unreachable,
            }
        }

        fn scope_close(self: *StateMachine, operation: Operation, mode: ScopeCloseMode) void {
            switch (operation) {
                .create_accounts => {
                    self.forest.grooves.accounts.scope_close(mode);
                },
                .create_transfers => {
                    self.forest.grooves.accounts.scope_close(mode);
                    self.forest.grooves.transfers.scope_close(mode);
                    self.forest.grooves.transfers_pending.scope_close(mode);
                    self.forest.grooves.account_balances.scope_close(mode);
                },
                else => unreachable,
            }
        }

        fn execute(
            self: *StateMachine,
            comptime operation: Operation,
            timestamp: u64,
            input: []align(16) const u8,
            output: *align(16) [constants.message_body_size_max]u8,
        ) usize {
            comptime assert(operation == .create_accounts or operation == .create_transfers);

            const events = mem.bytesAsSlice(Event(operation), input);
            var results = mem.bytesAsSlice(Result(operation), output);
            var count: usize = 0;

            var chain: ?usize = null;
            var chain_broken = false;

            for (events, 0..) |*event_, index| {
                var event = event_.*;

                const result = blk: {
                    if (event.flags.linked) {
                        if (chain == null) {
                            chain = index;
                            assert(chain_broken == false);
                            self.scope_open(operation);
                        }

                        if (index == events.len - 1) break :blk .linked_event_chain_open;
                    }

                    if (chain_broken) break :blk .linked_event_failed;
                    if (event.timestamp != 0) break :blk .timestamp_must_be_zero;

                    event.timestamp = timestamp - events.len + index + 1;
                    assert(event.timestamp >= TimestampRange.timestamp_min);
                    assert(event.timestamp <= TimestampRange.timestamp_max);

                    break :blk switch (operation) {
                        .create_accounts => self.create_account(&event),
                        .create_transfers => self.create_transfer(&event),
                        else => unreachable,
                    };
                };
                log.debug("{?}: {s} {}/{}: {}: {}", .{
                    self.forest.grid.superblock.replica_index,
                    @tagName(operation),
                    index + 1,
                    events.len,
                    result,
                    event,
                });
                if (result != .ok) {
                    if (chain) |chain_start_index| {
                        if (!chain_broken) {
                            chain_broken = true;
                            // Our chain has just been broken, discard the scope we started above.
                            self.scope_close(operation, .discard);

                            // Add errors for rolled back events in FIFO order:
                            var chain_index = chain_start_index;
                            while (chain_index < index) : (chain_index += 1) {
                                results[count] = .{
                                    .index = @intCast(chain_index),
                                    .result = .linked_event_failed,
                                };
                                count += 1;
                            }
                        } else {
                            assert(result == .linked_event_failed or
                                result == .linked_event_chain_open);
                        }
                    }
                    results[count] = .{ .index = @intCast(index), .result = result };
                    count += 1;
                }
                if (chain != null and (!event.flags.linked or result == .linked_event_chain_open)) {
                    if (!chain_broken) {
                        // We've finished this linked chain, and all events have applied
                        // successfully.
                        self.scope_close(operation, .persist);
                    }

                    chain = null;
                    chain_broken = false;
                }
            }
            assert(chain == null);
            assert(chain_broken == false);

            return @sizeOf(Result(operation)) * count;
        }

        // Accounts that do not fit in the response are omitted.
        fn execute_lookup_accounts(
            self: *StateMachine,
            input: []const u8,
            output: *align(16) [constants.message_body_size_max]u8,
        ) usize {
            const batch = mem.bytesAsSlice(u128, input);
            const output_len = @divFloor(output.len, @sizeOf(Account)) * @sizeOf(Account);
            const results = mem.bytesAsSlice(Account, output[0..output_len]);
            var results_count: usize = 0;
            for (batch) |id| {
                if (self.forest.grooves.accounts.get(id)) |account| {
                    results[results_count] = account.*;
                    results_count += 1;
                }
            }
            return results_count * @sizeOf(Account);
        }

        // Transfers that do not fit in the response are omitted.
        fn execute_lookup_transfers(
            self: *StateMachine,
            input: []const u8,
            output: *align(16) [constants.message_body_size_max]u8,
        ) usize {
            const batch = mem.bytesAsSlice(u128, input);
            const output_len = @divFloor(output.len, @sizeOf(Transfer)) * @sizeOf(Transfer);
            const results = mem.bytesAsSlice(Transfer, output[0..output_len]);
            var results_count: usize = 0;
            for (batch) |id| {
                if (self.get_transfer(id)) |result| {
                    results[results_count] = result.*;
                    results_count += 1;
                }
            }
            return results_count * @sizeOf(Transfer);
        }

        fn execute_get_account_transfers(
            self: *StateMachine,
            input: []const u8,
            output: *align(16) [constants.message_body_size_max]u8,
        ) usize {
            _ = input;
            if (self.scan_lookup_result_count == null) return 0; // invalid filter
            assert(self.scan_lookup_result_count.? <= constants.batch_max.get_account_transfers);

            defer self.scan_lookup_result_count = null;
            if (self.scan_lookup_result_count.? == 0) return 0; // no results found

            const result_size: usize = self.scan_lookup_result_count.? * @sizeOf(Transfer);
            assert(result_size <= output.len);
            assert(result_size <= self.scan_lookup_buffer.len);
            stdx.copy_disjoint(
                .exact,
                u8,
                output[0..result_size],
                self.scan_lookup_buffer[0..result_size],
            );

            return result_size;
        }

        fn execute_get_account_balances(
            self: *StateMachine,
            input: []const u8,
            output: *align(16) [constants.message_body_size_max]u8,
        ) usize {
            if (self.scan_lookup_result_count == null) return 0; // invalid filter
            assert(self.scan_lookup_result_count.? <= constants.batch_max.get_account_balances);

            defer self.scan_lookup_result_count = null;
            if (self.scan_lookup_result_count.? == 0) return 0; // no results found

            const filter: AccountFilter = mem.bytesToValue(
                AccountFilter,
                input[0..@sizeOf(AccountFilter)],
            );

            const scan_results: []const AccountBalancesGrooveValue = mem.bytesAsSlice(
                AccountBalancesGrooveValue,
                self.scan_lookup_buffer[0 .. self.scan_lookup_result_count.? *
                    @sizeOf(AccountBalancesGrooveValue)],
            );

            const output_slice: []AccountBalance = mem.bytesAsSlice(AccountBalance, output);
            var output_count: usize = 0;

            for (scan_results) |*result| {
                assert(result.dr_account_id != result.cr_account_id);

                output_slice[output_count] = if (filter.account_id == result.dr_account_id) .{
                    .timestamp = result.timestamp,
                    .debits_pending = result.dr_debits_pending,
                    .debits_posted = result.dr_debits_posted,
                    .credits_pending = result.dr_credits_pending,
                    .credits_posted = result.dr_credits_posted,
                } else if (filter.account_id == result.cr_account_id) .{
                    .timestamp = result.timestamp,
                    .debits_pending = result.cr_debits_pending,
                    .debits_posted = result.cr_debits_posted,
                    .credits_pending = result.cr_credits_pending,
                    .credits_posted = result.cr_credits_posted,
                } else {
                    // We have checked that this account has `flags.history == true`.
                    unreachable;
                };

                output_count += 1;
            }

            assert(output_count == self.scan_lookup_result_count.?);
            return output_count * @sizeOf(AccountBalance);
        }

        fn execute_query_accounts(
            self: *StateMachine,
            input: []const u8,
            output: *align(16) [constants.message_body_size_max]u8,
        ) usize {
            _ = input;
            if (self.scan_lookup_result_count == null) return 0; // invalid filter
            assert(self.scan_lookup_result_count.? <= constants.batch_max.query_accounts);

            defer self.scan_lookup_result_count = null;
            if (self.scan_lookup_result_count.? == 0) return 0; // no results found

            const result_size: usize = self.scan_lookup_result_count.? * @sizeOf(Account);
            assert(result_size <= output.len);
            assert(result_size <= self.scan_lookup_buffer.len);
            stdx.copy_disjoint(
                .exact,
                u8,
                output[0..result_size],
                self.scan_lookup_buffer[0..result_size],
            );
            return result_size;
        }

        fn execute_append_stream(
            self: *StateMachine,
            timestamp: u64,
            input: []align(16) const u8,
            output: *align(16) [constants.message_body_size_max]u8,
        ) usize {
            _ = output;
            const event = mem.bytesAsValue(RecordedEvent, input);
            event.timestamp = timestamp;
            self.forest.grooves.events.insert(event);
            self.commit_timestamp = timestamp;
            return 0;
        }

        fn execute_read_stream(
            self: *StateMachine,
            input: []const u8,
            output: *align(16) [constants.message_body_size_max]u8,
        ) usize {
            const stream_id = mem.readIntLittle(u128, input[0..16]);
            const events = self.forest.grooves.events.getMany(stream_id);
            const result_size = events.len * @sizeOf(Event);
            @memcpy(output[0..result_size], mem.sliceAsBytes(events));
            return result_size;
        }

        fn execute_read_all(
            self: *StateMachine,
            output: *align(16) [constants.message_body_size_max]u8,
        ) usize {
            const events = self.forest.grooves.events.getAll();
            const result_size = events.len * @sizeOf(Event);
            @memcpy(output[0..result_size], mem.sliceAsBytes(events));
            return result_size;
        }


        fn execute_query_transfers(
            self: *StateMachine,
            input: []const u8,
            output: *align(16) [constants.message_body_size_max]u8,
        ) usize {
            _ = input;
            if (self.scan_lookup_result_count == null) return 0; // invalid filter
            assert(self.scan_lookup_result_count.? <= constants.batch_max.query_transfers);

            defer self.scan_lookup_result_count = null;
            if (self.scan_lookup_result_count.? == 0) return 0; // no results found

            const result_size: usize = self.scan_lookup_result_count.? * @sizeOf(Transfer);
            assert(result_size <= output.len);
            assert(result_size <= self.scan_lookup_buffer.len);
            stdx.copy_disjoint(
                .exact,
                u8,
                output[0..result_size],
                self.scan_lookup_buffer[0..result_size],
            );
            return result_size;
        }

        fn create_account(self: *StateMachine, a: *const Account) CreateAccountResult {
            assert(a.timestamp > self.commit_timestamp or global_constants.aof_recovery);

            if (a.reserved != 0) return .reserved_field;
            if (a.flags.padding != 0) return .reserved_flag;

            if (a.id == 0) return .id_must_not_be_zero;
            if (a.id == math.maxInt(u128)) return .id_must_not_be_int_max;

            if (a.flags.debits_must_not_exceed_credits and a.flags.credits_must_not_exceed_debits) {
                return .flags_are_mutually_exclusive;
            }

            if (a.debits_pending != 0) return .debits_pending_must_be_zero;
            if (a.debits_posted != 0) return .debits_posted_must_be_zero;
            if (a.credits_pending != 0) return .credits_pending_must_be_zero;
            if (a.credits_posted != 0) return .credits_posted_must_be_zero;
            if (a.ledger == 0) return .ledger_must_not_be_zero;
            if (a.code == 0) return .code_must_not_be_zero;

            if (self.forest.grooves.accounts.get(a.id)) |e| {
                return create_account_exists(a, e);
            }

            self.forest.grooves.accounts.insert(a);
            self.commit_timestamp = a.timestamp;
            return .ok;
        }

        fn create_account_exists(a: *const Account, e: *const Account) CreateAccountResult {
            assert(a.id == e.id);
            if (@as(u16, @bitCast(a.flags)) != @as(u16, @bitCast(e.flags))) {
                return .exists_with_different_flags;
            }
            if (a.user_data_128 != e.user_data_128) return .exists_with_different_user_data_128;
            if (a.user_data_64 != e.user_data_64) return .exists_with_different_user_data_64;
            if (a.user_data_32 != e.user_data_32) return .exists_with_different_user_data_32;
            assert(a.reserved == 0 and e.reserved == 0);
            if (a.ledger != e.ledger) return .exists_with_different_ledger;
            if (a.code != e.code) return .exists_with_different_code;
            return .exists;
        }

        fn create_transfer(self: *StateMachine, t: *const Transfer) CreateTransferResult {
            assert(t.timestamp > self.commit_timestamp or global_constants.aof_recovery);

            if (t.flags.padding != 0) return .reserved_flag;

            if (t.id == 0) return .id_must_not_be_zero;
            if (t.id == math.maxInt(u128)) return .id_must_not_be_int_max;

            if (t.flags.post_pending_transfer or t.flags.void_pending_transfer) {
                return self.post_or_void_pending_transfer(t);
            }

            if (t.debit_account_id == 0) return .debit_account_id_must_not_be_zero;
            if (t.debit_account_id == math.maxInt(u128)) {
                return .debit_account_id_must_not_be_int_max;
            }
            if (t.credit_account_id == 0) return .credit_account_id_must_not_be_zero;
            if (t.credit_account_id == math.maxInt(u128)) {
                return .credit_account_id_must_not_be_int_max;
            }
            if (t.credit_account_id == t.debit_account_id) return .accounts_must_be_different;

            if (t.pending_id != 0) return .pending_id_must_be_zero;
            if (!t.flags.pending) {
                if (t.timeout != 0) return .timeout_reserved_for_pending_transfer;
            }
            if (!t.flags.balancing_debit and !t.flags.balancing_credit) {
                if (t.amount == 0) return .amount_must_not_be_zero;
            }

            if (t.ledger == 0) return .ledger_must_not_be_zero;
            if (t.code == 0) return .code_must_not_be_zero;

            // The etymology of the DR and CR abbreviations for debit/credit is interesting, either:
            // 1. derived from the Latin past participles of debitum/creditum, i.e. debere/credere,
            // 2. standing for debit record and credit record, or
            // 3. relating to debtor and creditor.
            // We use them to distinguish between `cr` (credit account), and `c` (commit).
            const dr_account = self.forest.grooves.accounts.get(t.debit_account_id) orelse
                return .debit_account_not_found;
            const cr_account = self.forest.grooves.accounts.get(t.credit_account_id) orelse
                return .credit_account_not_found;
            assert(dr_account.id == t.debit_account_id);
            assert(cr_account.id == t.credit_account_id);
            assert(t.timestamp > dr_account.timestamp);
            assert(t.timestamp > cr_account.timestamp);

            if (dr_account.ledger != cr_account.ledger) return .accounts_must_have_the_same_ledger;
            if (t.ledger != dr_account.ledger) {
                return .transfer_must_have_the_same_ledger_as_accounts;
            }

            // If the transfer already exists, then it must not influence the overflow or limit
            // checks.
            if (self.get_transfer(t.id)) |e| return create_transfer_exists(t, e);

            const amount = amount: {
                var amount = t.amount;
                if (t.flags.balancing_debit or t.flags.balancing_credit) {
                    if (amount == 0) amount = std.math.maxInt(u64);
                } else {
                    assert(amount != 0);
                }

                if (t.flags.balancing_debit) {
                    const dr_balance = dr_account.debits_posted + dr_account.debits_pending;
                    amount = @min(amount, dr_account.credits_posted -| dr_balance);
                    if (amount == 0) return .exceeds_credits;
                }

                if (t.flags.balancing_credit) {
                    const cr_balance = cr_account.credits_posted + cr_account.credits_pending;
                    amount = @min(amount, cr_account.debits_posted -| cr_balance);
                    if (amount == 0) return .exceeds_debits;
                }
                break :amount amount;
            };

            if (t.flags.pending) {
                if (sum_overflows(u128, amount, dr_account.debits_pending)) {
                    return .overflows_debits_pending;
                }
                if (sum_overflows(u128, amount, cr_account.credits_pending)) {
                    return .overflows_credits_pending;
                }
            }
            if (sum_overflows(u128, amount, dr_account.debits_posted)) {
                return .overflows_debits_posted;
            }
            if (sum_overflows(u128, amount, cr_account.credits_posted)) {
                return .overflows_credits_posted;
            }
            // We assert that the sum of the pending and posted balances can never overflow:
            if (sum_overflows(
                u128,
                amount,
                dr_account.debits_pending + dr_account.debits_posted,
            )) {
                return .overflows_debits;
            }
            if (sum_overflows(
                u128,
                amount,
                cr_account.credits_pending + cr_account.credits_posted,
            )) {
                return .overflows_credits;
            }

            // Comptime asserts that the max value of the timeout expressed in seconds cannot
            // overflow a `u63` when converted to nanoseconds.
            // It is `u63` because the most significant bit of the `u64` timestamp
            // is used as the tombstone flag.
            comptime assert(!std.meta.isError(std.math.mul(
                u63,
                @as(u63, std.math.maxInt(@TypeOf(t.timeout))),
                std.time.ns_per_s,
            )));
            if (sum_overflows(
                u63,
                @intCast(t.timestamp),
                @as(u63, t.timeout) * std.time.ns_per_s,
            )) {
                return .overflows_timeout;
            }

            if (dr_account.debits_exceed_credits(amount)) return .exceeds_credits;
            if (cr_account.credits_exceed_debits(amount)) return .exceeds_debits;

            // After this point, the transfer must succeed.
            defer assert(self.commit_timestamp == t.timestamp);

            var t2 = t.*;
            t2.amount = amount;
            self.forest.grooves.transfers.insert(&t2);

            var dr_account_new = dr_account.*;
            var cr_account_new = cr_account.*;
            if (t.flags.pending) {
                dr_account_new.debits_pending += amount;
                cr_account_new.credits_pending += amount;

                self.forest.grooves.transfers_pending.insert(&.{
                    .timestamp = t2.timestamp,
                    .status = .pending,
                });
            } else {
                dr_account_new.debits_posted += amount;
                cr_account_new.credits_posted += amount;
            }
            self.forest.grooves.accounts.update(.{ .old = dr_account, .new = &dr_account_new });
            self.forest.grooves.accounts.update(.{ .old = cr_account, .new = &cr_account_new });

            self.historical_balance(.{
                .transfer = &t2,
                .dr_account = &dr_account_new,
                .cr_account = &cr_account_new,
            });

            if (t.timeout > 0) {
                const expires_at = t.timestamp + t.timeout_ns();
                if (expires_at < self.expire_pending_transfers.pulse_next_timestamp) {
                    self.expire_pending_transfers.pulse_next_timestamp = expires_at;
                }
            }

            self.commit_timestamp = t.timestamp;
            return .ok;
        }

        fn create_transfer_exists(t: *const Transfer, e: *const Transfer) CreateTransferResult {
            assert(t.id == e.id);
            // The flags change the behavior of the remaining comparisons, so compare the flags
            // first.
            if (@as(u16, @bitCast(t.flags)) != @as(u16, @bitCast(e.flags))) {
                return .exists_with_different_flags;
            }
            // We know that the flags are the same.
            assert(t.pending_id == 0 and e.pending_id == 0);

            if (t.debit_account_id != e.debit_account_id) {
                return .exists_with_different_debit_account_id;
            }
            if (t.credit_account_id != e.credit_account_id) {
                return .exists_with_different_credit_account_id;
            }
            // If the accounts are the same, the ledger must be the same.
            assert(t.ledger == e.ledger);

            // In transfers with `flags.balancing_debit = true` or `flags.balancing_credit = true`,
            // the field `amount` means the _upper limit_ (or zero for `maxInt`) that can be moved
            // in order to balance debits and credits.
            // The actual amount moved depends on the account's balance at the time the transfer
            // was executed.
            //
            // This is a special case in the idempotency check:
            // When _resubmitting_ the same balancing transfer, the amount will likely be different
            // from what was previously committed, but as long as it is within the range of possible
            // values it should fail with `exists` rather than `exists_with_different_amount`.
            if (t.flags.balancing_debit or t.flags.balancing_credit) {
                if (t.amount > 0 and t.amount < e.amount) return .exists_with_different_amount;
            } else {
                if (t.amount != e.amount) return .exists_with_different_amount;
            }

            if (t.user_data_128 != e.user_data_128) return .exists_with_different_user_data_128;
            if (t.user_data_64 != e.user_data_64) return .exists_with_different_user_data_64;
            if (t.user_data_32 != e.user_data_32) return .exists_with_different_user_data_32;
            if (t.timeout != e.timeout) return .exists_with_different_timeout;
            if (t.code != e.code) return .exists_with_different_code;
            return .exists;
        }

        fn post_or_void_pending_transfer(
            self: *StateMachine,
            t: *const Transfer,
        ) CreateTransferResult {
            assert(t.id != 0);
            assert(t.flags.padding == 0);
            assert(t.timestamp > self.commit_timestamp);
            assert(t.flags.post_pending_transfer or t.flags.void_pending_transfer);

            if (t.flags.post_pending_transfer and t.flags.void_pending_transfer) {
                return .flags_are_mutually_exclusive;
            }
            if (t.flags.pending) return .flags_are_mutually_exclusive;
            if (t.flags.balancing_debit) return .flags_are_mutually_exclusive;
            if (t.flags.balancing_credit) return .flags_are_mutually_exclusive;

            if (t.pending_id == 0) return .pending_id_must_not_be_zero;
            if (t.pending_id == math.maxInt(u128)) return .pending_id_must_not_be_int_max;
            if (t.pending_id == t.id) return .pending_id_must_be_different;
            if (t.timeout != 0) return .timeout_reserved_for_pending_transfer;

            const p = self.get_transfer(t.pending_id) orelse return .pending_transfer_not_found;
            assert(p.id == t.pending_id);
            assert(p.timestamp < t.timestamp);
            if (!p.flags.pending) return .pending_transfer_not_pending;

            const dr_account = self.forest.grooves.accounts.get(p.debit_account_id).?;
            const cr_account = self.forest.grooves.accounts.get(p.credit_account_id).?;
            assert(dr_account.id == p.debit_account_id);
            assert(cr_account.id == p.credit_account_id);
            assert(p.timestamp > dr_account.timestamp);
            assert(p.timestamp > cr_account.timestamp);
            assert(p.amount > 0);

            if (t.debit_account_id > 0 and t.debit_account_id != p.debit_account_id) {
                return .pending_transfer_has_different_debit_account_id;
            }
            if (t.credit_account_id > 0 and t.credit_account_id != p.credit_account_id) {
                return .pending_transfer_has_different_credit_account_id;
            }
            // The user_data field is allowed to differ across pending and posting/voiding
            // transfers.
            if (t.ledger > 0 and t.ledger != p.ledger) {
                return .pending_transfer_has_different_ledger;
            }
            if (t.code > 0 and t.code != p.code) return .pending_transfer_has_different_code;

            const amount = if (t.amount > 0) t.amount else p.amount;
            if (amount > p.amount) return .exceeds_pending_transfer_amount;

            if (t.flags.void_pending_transfer and amount < p.amount) {
                return .pending_transfer_has_different_amount;
            }

            if (self.get_transfer(t.id)) |e| return post_or_void_pending_transfer_exists(t, e, p);

            const transfer_pending = self.get_transfer_pending(p.timestamp).?;
            assert(p.timestamp == transfer_pending.timestamp);
            switch (transfer_pending.status) {
                .none => unreachable,
                .pending => {},
                .posted => return .pending_transfer_already_posted,
                .voided => return .pending_transfer_already_voided,
                .expired => {
                    assert(p.timeout > 0);
                    assert(t.timestamp >= p.timestamp + p.timeout_ns());
                    return .pending_transfer_expired;
                },
            }

            const expires_at_maybe: ?u64 = if (p.timeout == 0) null else expires_at: {
                const expires_at = p.timestamp + p.timeout_ns();
                if (expires_at <= t.timestamp) {
                    // TODO: It's still possible for an operation to see an expired transfer
                    // if there's more than one batch of transfers to expire in a single `pulse`
                    // and the current operation was pipelined before the expiration commits.
                    return .pending_transfer_expired;
                }

                break :expires_at expires_at;
            };

            // After this point, the transfer must succeed.
            defer assert(self.commit_timestamp == t.timestamp);

            const t2 = Transfer{
                .id = t.id,
                .debit_account_id = p.debit_account_id,
                .credit_account_id = p.credit_account_id,
                .user_data_128 = if (t.user_data_128 > 0) t.user_data_128 else p.user_data_128,
                .user_data_64 = if (t.user_data_64 > 0) t.user_data_64 else p.user_data_64,
                .user_data_32 = if (t.user_data_32 > 0) t.user_data_32 else p.user_data_32,
                .ledger = p.ledger,
                .code = p.code,
                .pending_id = t.pending_id,
                .timeout = 0,
                .timestamp = t.timestamp,
                .flags = t.flags,
                .amount = amount,
            };
            self.forest.grooves.transfers.insert(&t2);

            if (expires_at_maybe) |expires_at| {
                // Removing the pending `expires_at` index.
                self.forest.grooves.transfers.indexes.expires_at.remove(&.{
                    .field = expires_at,
                    .timestamp = p.timestamp,
                });

                // In case the pending transfer's timeout is exactly the one we are using
                // as flag, we need to zero the value to run the next `pulse`.
                if (self.expire_pending_transfers.pulse_next_timestamp == expires_at) {
                    self.expire_pending_transfers.pulse_next_timestamp =
                        TimestampRange.timestamp_min;
                }
            }

            self.transfer_update_pending_status(transfer_pending, status: {
                if (t.flags.post_pending_transfer) break :status .posted;
                if (t.flags.void_pending_transfer) break :status .voided;
                unreachable;
            });

            var dr_account_new = dr_account.*;
            var cr_account_new = cr_account.*;
            dr_account_new.debits_pending -= p.amount;
            cr_account_new.credits_pending -= p.amount;

            if (t.flags.post_pending_transfer) {
                assert(amount > 0);
                assert(amount <= p.amount);
                dr_account_new.debits_posted += amount;
                cr_account_new.credits_posted += amount;
            }

            self.forest.grooves.accounts.update(.{ .old = dr_account, .new = &dr_account_new });
            self.forest.grooves.accounts.update(.{ .old = cr_account, .new = &cr_account_new });

            self.historical_balance(.{
                .transfer = &t2,
                .dr_account = &dr_account_new,
                .cr_account = &cr_account_new,
            });

            self.commit_timestamp = t.timestamp;

            return .ok;
        }

        fn post_or_void_pending_transfer_exists(
            t: *const Transfer,
            e: *const Transfer,
            p: *const Transfer,
        ) CreateTransferResult {
            assert(t.id == e.id);
            assert(t.id != p.id);
            assert(p.flags.pending);
            assert(t.pending_id == p.id);

            // Do not assume that `e` is necessarily a posting or voiding transfer.
            if (@as(u16, @bitCast(t.flags)) != @as(u16, @bitCast(e.flags))) {
                return .exists_with_different_flags;
            }

            if (t.amount == 0) {
                if (e.amount != p.amount) return .exists_with_different_amount;
            } else {
                if (t.amount != e.amount) return .exists_with_different_amount;
            }

            // If `e` posted or voided a different pending transfer, then the accounts will differ.
            if (t.pending_id != e.pending_id) return .exists_with_different_pending_id;

            assert(e.flags.post_pending_transfer or e.flags.void_pending_transfer);
            assert(e.debit_account_id == p.debit_account_id);
            assert(e.credit_account_id == p.credit_account_id);
            assert(e.pending_id == p.id);
            assert(e.timeout == 0);
            assert(e.ledger == p.ledger);
            assert(e.code == p.code);
            assert(e.timestamp > p.timestamp);

            assert(t.flags.post_pending_transfer == e.flags.post_pending_transfer);
            assert(t.flags.void_pending_transfer == e.flags.void_pending_transfer);
            assert(t.debit_account_id == 0 or t.debit_account_id == e.debit_account_id);
            assert(t.credit_account_id == 0 or t.credit_account_id == e.credit_account_id);
            assert(t.timeout == 0);
            assert(t.ledger == 0 or t.ledger == e.ledger);
            assert(t.code == 0 or t.code == e.code);
            assert(t.timestamp > e.timestamp);

            if (t.user_data_128 == 0) {
                if (e.user_data_128 != p.user_data_128) return .exists_with_different_user_data_128;
            } else {
                if (t.user_data_128 != e.user_data_128) return .exists_with_different_user_data_128;
            }

            if (t.user_data_64 == 0) {
                if (e.user_data_64 != p.user_data_64) return .exists_with_different_user_data_64;
            } else {
                if (t.user_data_64 != e.user_data_64) return .exists_with_different_user_data_64;
            }

            if (t.user_data_32 == 0) {
                if (e.user_data_32 != p.user_data_32) return .exists_with_different_user_data_32;
            } else {
                if (t.user_data_32 != e.user_data_32) return .exists_with_different_user_data_32;
            }

            return .exists;
        }

        fn historical_balance(
            self: *StateMachine,
            args: struct {
                transfer: *const Transfer,
                dr_account: *const Account,
                cr_account: *const Account,
            },
        ) void {
            assert(args.transfer.timestamp > 0);
            assert(args.transfer.debit_account_id == args.dr_account.id);
            assert(args.transfer.credit_account_id == args.cr_account.id);

            if (args.dr_account.flags.history or args.cr_account.flags.history) {
                var balance = std.mem.zeroInit(AccountBalancesGrooveValue, .{
                    .timestamp = args.transfer.timestamp,
                });

                if (args.dr_account.flags.history) {
                    balance.dr_account_id = args.dr_account.id;
                    balance.dr_debits_pending = args.dr_account.debits_pending;
                    balance.dr_debits_posted = args.dr_account.debits_posted;
                    balance.dr_credits_pending = args.dr_account.credits_pending;
                    balance.dr_credits_posted = args.dr_account.credits_posted;
                }

                if (args.cr_account.flags.history) {
                    balance.cr_account_id = args.cr_account.id;
                    balance.cr_debits_pending = args.cr_account.debits_pending;
                    balance.cr_debits_posted = args.cr_account.debits_posted;
                    balance.cr_credits_pending = args.cr_account.credits_pending;
                    balance.cr_credits_posted = args.cr_account.credits_posted;
                }

                self.forest.grooves.account_balances.insert(&balance);
            }
        }

        fn get_transfer(self: *const StateMachine, id: u128) ?*const Transfer {
            return self.forest.grooves.transfers.get(id);
        }

        /// Returns whether a pending transfer, if it exists, has already been
        /// posted,voided, or expired.
        fn get_transfer_pending(
            self: *const StateMachine,
            pending_timestamp: u64,
        ) ?*const TransferPending {
            return self.forest.grooves.transfers_pending.get(pending_timestamp);
        }

        fn transfer_update_pending_status(
            self: *StateMachine,
            transfer_pending: *const TransferPending,
            status: TransferPendingStatus,
        ) void {
            assert(transfer_pending.timestamp != 0);
            assert(transfer_pending.status == .pending);
            assert(status != .none and status != .pending);

            self.forest.grooves.transfers_pending.update(.{
                .old = transfer_pending,
                .new = &.{
                    .timestamp = transfer_pending.timestamp,
                    .status = status,
                },
            });
        }

        fn execute_expire_pending_transfers(self: *StateMachine, timestamp: u64) usize {
            assert(self.scan_lookup_result_count != null);
            assert(self.scan_lookup_result_count.? <= constants.batch_max.create_transfers);

            defer self.scan_lookup_result_count = null;
            if (self.scan_lookup_result_count.? == 0) return 0;

            const grooves = &self.forest.grooves;
            const transfers: []const Transfer = std.mem.bytesAsSlice(
                Transfer,
                self.scan_lookup_buffer[0 .. self.scan_lookup_result_count.? * @sizeOf(Transfer)],
            );

            log.debug("expire_pending_transfers: len={}", .{transfers.len});

            for (transfers) |expired| {
                assert(expired.flags.pending);
                assert(expired.timeout > 0);
                assert(expired.amount > 0);

                const expires_at = expired.timestamp + expired.timeout_ns();
                assert(expires_at <= timestamp);

                const dr_account = grooves.accounts.get(
                    expired.debit_account_id,
                ).?;
                assert(dr_account.debits_pending >= expired.amount);

                const cr_account = grooves.accounts.get(
                    expired.credit_account_id,
                ).?;
                assert(cr_account.credits_pending >= expired.amount);

                var dr_account_new = dr_account.*;
                var cr_account_new = cr_account.*;
                dr_account_new.debits_pending -= expired.amount;
                cr_account_new.credits_pending -= expired.amount;

                grooves.accounts.update(.{ .old = dr_account, .new = &dr_account_new });
                grooves.accounts.update(.{ .old = cr_account, .new = &cr_account_new });

                const transfer_pending = self.get_transfer_pending(expired.timestamp).?;
                assert(expired.timestamp == transfer_pending.timestamp);
                assert(transfer_pending.status == .pending);
                self.transfer_update_pending_status(transfer_pending, .expired);

                // Removing the `expires_at` index.
                grooves.transfers.indexes.expires_at.remove(&.{
                    .timestamp = expired.timestamp,
                    .field = expires_at,
                });
            }

            // This operation has no output.
            return 0;
        }

        pub fn forest_options(options: Options) Forest.GroovesOptions {
            const batch_values_limit = batch_value_counts_limit(options.batch_size_limit);

            const batch_accounts_limit: u32 =
                @divFloor(options.batch_size_limit, @sizeOf(Account));
            const batch_transfers_limit: u32 =
                @divFloor(options.batch_size_limit, @sizeOf(Transfer));
            assert(batch_accounts_limit > 0);
            assert(batch_transfers_limit > 0);
            assert(batch_accounts_limit <= constants.batch_max.create_accounts);
            assert(batch_accounts_limit <= constants.batch_max.lookup_accounts);
            assert(batch_transfers_limit <= constants.batch_max.create_transfers);
            assert(batch_transfers_limit <= constants.batch_max.lookup_transfers);

            if (options.batch_size_limit == config.message_body_size_max) {
                assert(batch_accounts_limit == constants.batch_max.create_accounts);
                assert(batch_accounts_limit == constants.batch_max.lookup_accounts);
                assert(batch_transfers_limit == constants.batch_max.create_transfers);
                assert(batch_transfers_limit == constants.batch_max.lookup_transfers);
            }

            return .{
                .accounts = .{
                    // lookup_account() looks up 1 Account per item.
                    .prefetch_entries_for_read_max = batch_accounts_limit,
                    .prefetch_entries_for_update_max = @max(
                        batch_accounts_limit, // create_account()
                        2 * batch_transfers_limit, // create_transfer(), debit and credit accounts
                    ),
                    .cache_entries_max = options.cache_entries_accounts,
                    .tree_options_object = .{
                        .batch_value_count_limit = batch_values_limit.accounts.timestamp,
                    },
                    .tree_options_id = .{
                        .batch_value_count_limit = batch_values_limit.accounts.id,
                    },
                    .tree_options_index = index_tree_options(
                        AccountsGroove.IndexTreeOptions,
                        batch_values_limit.accounts,
                    ),
                },
                .transfers = .{
                    // lookup_transfer() looks up 1 Transfer.
                    // create_transfer() looks up at most 1 Transfer for posting/voiding.
                    .prefetch_entries_for_read_max = batch_transfers_limit,
                    // create_transfer() updates a single Transfer.
                    .prefetch_entries_for_update_max = batch_transfers_limit,
                    .cache_entries_max = options.cache_entries_transfers,
                    .tree_options_object = .{
                        .batch_value_count_limit = batch_values_limit.transfers.timestamp,
                    },
                    .tree_options_id = .{
                        .batch_value_count_limit = batch_values_limit.transfers.id,
                    },
                    .tree_options_index = index_tree_options(
                        TransfersGroove.IndexTreeOptions,
                        batch_values_limit.transfers,
                    ),
                },
                .transfers_pending = .{
                    .prefetch_entries_for_read_max = batch_transfers_limit,
                    // create_transfer() posts/voids at most one transfer.
                    .prefetch_entries_for_update_max = batch_transfers_limit,
                    .cache_entries_max = options.cache_entries_posted,
                    .tree_options_object = .{
                        .batch_value_count_limit = batch_values_limit.transfers_pending.timestamp,
                    },
                    .tree_options_id = {},
                    .tree_options_index = index_tree_options(
                        TransfersPendingGroove.IndexTreeOptions,
                        batch_values_limit.transfers_pending,
                    ),
                },
                .account_balances = .{
                    .prefetch_entries_for_read_max = 0,
                    .prefetch_entries_for_update_max = batch_transfers_limit,
                    .cache_entries_max = options.cache_entries_account_balances,
                    .tree_options_object = .{
                        .batch_value_count_limit = batch_values_limit.account_balances.timestamp,
                    },
                    .tree_options_id = {},
                    .tree_options_index = .{},
                },
            };
        }

        fn index_tree_options(
            comptime IndexTreeOptions: type,
            batch_limits: anytype,
        ) IndexTreeOptions {
            var result: IndexTreeOptions = undefined;
            inline for (comptime std.meta.fieldNames(IndexTreeOptions)) |field| {
                @field(result, field) = .{ .batch_value_count_limit = @field(batch_limits, field) };
            }
            return result;
        }

        fn batch_value_counts_limit(batch_size_limit: u32) struct {
            accounts: struct {
                id: u32,
                user_data_128: u32,
                user_data_64: u32,
                user_data_32: u32,
                ledger: u32,
                code: u32,
                timestamp: u32,
            },
            transfers: struct {
                timestamp: u32,
                id: u32,
                debit_account_id: u32,
                credit_account_id: u32,
                amount: u32,
                pending_id: u32,
                user_data_128: u32,
                user_data_64: u32,
                user_data_32: u32,
                ledger: u32,
                code: u32,
                expires_at: u32,
            },
            transfers_pending: struct {
                timestamp: u32,
                status: u32,
            },
            account_balances: struct {
                timestamp: u32,
            },
        } {
            assert(batch_size_limit <= constants.message_body_size_max);

            const batch_create_accounts = operation_batch_max(.create_accounts, batch_size_limit);
            const batch_create_transfers = operation_batch_max(.create_transfers, batch_size_limit);
            assert(batch_create_accounts > 0);
            assert(batch_create_transfers > 0);

            return .{
                .accounts = .{
                    .id = batch_create_accounts,
                    .user_data_128 = batch_create_accounts,
                    .user_data_64 = batch_create_accounts,
                    .user_data_32 = batch_create_accounts,
                    .ledger = batch_create_accounts,
                    .code = batch_create_accounts,
                    // Transfers mutate the account balance for debits/credits pending/posted.
                    // Each transfer modifies two accounts.
                    .timestamp = @max(batch_create_accounts, 2 * batch_create_transfers),
                },
                .transfers = .{
                    .timestamp = batch_create_transfers,
                    .id = batch_create_transfers,
                    .debit_account_id = batch_create_transfers,
                    .credit_account_id = batch_create_transfers,
                    .amount = batch_create_transfers,
                    .pending_id = batch_create_transfers,
                    .user_data_128 = batch_create_transfers,
                    .user_data_64 = batch_create_transfers,
                    .user_data_32 = batch_create_transfers,
                    .ledger = batch_create_transfers,
                    .code = batch_create_transfers,
                    .expires_at = batch_create_transfers,
                },
                .transfers_pending = .{
                    // Objects are mutated when the pending transfer is posted/voided/expired.
                    .timestamp = 2 * batch_create_transfers,
                    .status = 2 * batch_create_transfers,
                },
                .account_balances = .{
                    .timestamp = batch_create_transfers,
                },
            };
        }

        pub fn operation_batch_max(comptime operation: Operation, batch_size_limit: u32) u32 {
            assert(batch_size_limit <= constants.message_body_size_max);

            const event_size = @sizeOf(Event(operation));
            const result_size = @sizeOf(Result(operation));
            comptime assert(event_size > 0);
            comptime assert(result_size > 0);

            return @min(
                @divFloor(batch_size_limit, event_size),
                @divFloor(constants.message_body_size_max, result_size),
            );
        }
    };
}

fn sum_overflows(comptime Int: type, a: Int, b: Int) bool {
    comptime assert(Int != comptime_int);
    comptime assert(Int != comptime_float);
    _ = std.math.add(Int, a, b) catch return true;
    return false;
}

/// Scans all `Transfers` that already expired at any timestamp.
/// A custom evaluator is used to stop at the first result where
/// `expires_at > prefetch_timestamp` while updating the next pulse timestamp.
/// This way we can achieve the same effect of two conditions with a single scan:
/// ```
/// WHERE expires_at <= prefetch_timestamp
/// UNION
/// WHERE expires_at > prefetch_timestamp LIMIT 1
/// ```
fn ExpirePendingTransfersType(
    comptime TransfersGroove: type,
    comptime Storage: type,
) type {
    return struct {
        const ExpirePendingTransfers = @This();
        const ScanRangeType = @import("lsm/scan_range.zig").ScanRangeType;
        const EvaluateNext = @import("lsm/scan_range.zig").EvaluateNext;
        const ScanLookupStatus = @import("lsm/scan_lookup.zig").ScanLookupStatus;

        const Tree = std.meta.FieldType(TransfersGroove.IndexTrees, .expires_at);
        const Key = Tree.Table.Key;
        const Value = Tree.Table.Value;

        // TODO(zig) Context should be `*ExpirePendingTransfers`,
        // but its a dependency loop.
        const Context = struct {};
        const ScanRange = ScanRangeType(
            Tree,
            Storage,
            *Context,
            value_next,
            timestamp_from_value,
        );

        pub const ScanLookup = ScanLookupType(
            TransfersGroove,
            ScanRange,
            Storage,
        );

        context: Context = undefined,
        phase: union(enum) {
            idle,
            running: struct {
                scan: ScanRange,
                expires_at_max: u64,
            },
        } = .idle,

        /// Used by the state machine to determine "when" it needs to execute the expiration logic:
        /// - When `== timestamp_min`, there may be pending transfers to expire,
        ///   but we need to scan to check.
        /// - When `== timestamp_max`, there are no pending transfers to expire.
        /// - Otherwise, this is the timestamp of the next pending transfer expiry.
        pulse_next_timestamp: u64 = TimestampRange.timestamp_min,
        value_next_expired_at: ?u64 = null,

        fn reset(self: *ExpirePendingTransfers) void {
            assert(self.phase == .idle);
            self.* = .{};
        }

        fn scan(
            self: *ExpirePendingTransfers,
            tree: *Tree,
            buffer: *const ScanBuffer,
            filter: struct {
                snapshot: u64,
                /// Will fetch transfers expired before this timestamp (inclusive).
                expires_at_max: u64,
            },
        ) *ScanRange {
            assert(self.phase == .idle);
            assert(filter.expires_at_max >= TimestampRange.timestamp_min and
                filter.expires_at_max <= TimestampRange.timestamp_max);
            maybe(filter.expires_at_max != TimestampRange.timestamp_min and
                filter.expires_at_max != TimestampRange.timestamp_max and
                self.pulse_next_timestamp > filter.expires_at_max);

            self.* = .{
                .pulse_next_timestamp = self.pulse_next_timestamp,
                .phase = .{ .running = .{
                    .expires_at_max = filter.expires_at_max,
                    .scan = ScanRange.init(
                        &self.context,
                        tree,
                        buffer,
                        filter.snapshot,
                        Tree.Table.key_from_value(&.{
                            .field = TimestampRange.timestamp_min,
                            .timestamp = TimestampRange.timestamp_min,
                        }),
                        Tree.Table.key_from_value(&.{
                            .field = TimestampRange.timestamp_max,
                            .timestamp = TimestampRange.timestamp_max,
                        }),
                        .ascending,
                    ),
                } },
            };
            return &self.phase.running.scan;
        }

        fn finish(
            self: *ExpirePendingTransfers,
            status: ScanLookupStatus,
            results: []const Transfer,
        ) void {
            assert(self.phase == .running);
            if (self.phase.running.expires_at_max != TimestampRange.timestamp_min and
                self.phase.running.expires_at_max != TimestampRange.timestamp_max and
                self.pulse_next_timestamp > self.phase.running.expires_at_max)
            {
                assert(results.len == 0);
            }

            switch (status) {
                .scan_finished => {
                    if (self.value_next_expired_at == null or
                        self.value_next_expired_at.? <= self.phase.running.expires_at_max)
                    {
                        // There are no more unexpired transfers left to expire in the next pulse.
                        self.pulse_next_timestamp = TimestampRange.timestamp_max;
                    } else {
                        self.pulse_next_timestamp = self.value_next_expired_at.?;
                    }
                },
                .buffer_finished => {
                    // There are more transfers to expire than a single batch.
                    assert(self.value_next_expired_at != null);
                    self.pulse_next_timestamp = self.value_next_expired_at.?;
                },
                else => unreachable,
            }
            self.phase = .idle;
            self.value_next_expired_at = null;
        }

        inline fn value_next(context: *Context, value: *const Value) EvaluateNext {
            const self: *ExpirePendingTransfers = @alignCast(@fieldParentPtr(
                "context",
                context,
            ));
            assert(self.phase == .running);

            const expires_at: u64 = value.field;

            assert(self.value_next_expired_at == null or
                self.value_next_expired_at.? <= expires_at);

            self.value_next_expired_at = expires_at;

            return if (expires_at <= self.phase.running.expires_at_max)
                .include_and_continue
            else
                .exclude_and_stop;
        }

        inline fn timestamp_from_value(context: *Context, value: *const Value) u64 {
            _ = context;
            return value.timestamp;
        }
    };
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

fn sum_overflows_test(comptime Int: type) !void {
    try expectEqual(false, sum_overflows(Int, math.maxInt(Int), 0));
    try expectEqual(false, sum_overflows(Int, math.maxInt(Int) - 1, 1));
    try expectEqual(false, sum_overflows(Int, 1, math.maxInt(Int) - 1));

    try expectEqual(true, sum_overflows(Int, math.maxInt(Int), 1));
    try expectEqual(true, sum_overflows(Int, 1, math.maxInt(Int)));

    try expectEqual(true, sum_overflows(Int, math.maxInt(Int), math.maxInt(Int)));
    try expectEqual(true, sum_overflows(Int, math.maxInt(Int), math.maxInt(Int)));
}

test "sum_overflows" {
    try sum_overflows_test(u64);
    try sum_overflows_test(u128);
}

const TestContext = struct {
    const Storage = @import("testing/storage.zig").Storage;
    const data_file_size_min = @import("vsr/superblock.zig").data_file_size_min;
    const SuperBlock = @import("vsr/superblock.zig").SuperBlockType(Storage);
    const Grid = @import("vsr/grid.zig").GridType(Storage);
    const StateMachine = StateMachineType(Storage, .{
        // Overestimate the batch size because the test never compacts.
        .message_body_size_max = TestContext.message_body_size_max,
        .lsm_batch_multiple = global_constants.lsm_batch_multiple,
        .vsr_operations_reserved = 128,
    });
    const message_body_size_max = 64 * @max(@sizeOf(Account), @sizeOf(Transfer));

    storage: Storage,
    superblock: SuperBlock,
    grid: Grid,
    state_machine: StateMachine,
    busy: bool = false,

    fn init(ctx: *TestContext, allocator: mem.Allocator) !void {
        ctx.storage = try Storage.init(
            allocator,
            4096,
            .{
                .read_latency_min = 0,
                .read_latency_mean = 0,
                .write_latency_min = 0,
                .write_latency_mean = 0,
            },
        );
        errdefer ctx.storage.deinit(allocator);

        ctx.superblock = try SuperBlock.init(allocator, .{
            .storage = &ctx.storage,
            .storage_size_limit = data_file_size_min,
        });
        errdefer ctx.superblock.deinit(allocator);

        // Pretend that the superblock is open so that the Forest can initialize.
        ctx.superblock.opened = true;
        ctx.superblock.working.vsr_state.checkpoint.header.op = 0;

        ctx.grid = try Grid.init(allocator, .{
            .superblock = &ctx.superblock,
            .missing_blocks_max = 0,
            .missing_tables_max = 0,
        });
        errdefer ctx.grid.deinit(allocator);

        ctx.state_machine = try StateMachine.init(allocator, &ctx.grid, .{
            .batch_size_limit = message_body_size_max,
            .lsm_forest_compaction_block_count = StateMachine.Forest.Options
                .compaction_block_count_min,
            .lsm_forest_node_count = 1,
            .cache_entries_accounts = 0,
            .cache_entries_transfers = 0,
            .cache_entries_posted = 0,
            .cache_entries_account_balances = 0,
        });
        errdefer ctx.state_machine.deinit(allocator);
    }

    fn deinit(ctx: *TestContext, allocator: mem.Allocator) void {
        ctx.storage.deinit(allocator);
        ctx.superblock.deinit(allocator);
        ctx.grid.deinit(allocator);
        ctx.state_machine.deinit(allocator);
        ctx.* = undefined;
    }

    fn callback(state_machine: *StateMachine) void {
        const ctx: *TestContext = @fieldParentPtr("state_machine", state_machine);
        assert(ctx.busy);
        ctx.busy = false;
    }

    fn execute(
        context: *TestContext,
        op: u64,
        operation: TestContext.StateMachine.Operation,
        input: []align(16) const u8,
        output: *align(16) [message_body_size_max]u8,
    ) usize {
        const timestamp = context.state_machine.prepare_timestamp;

        context.busy = true;
        context.state_machine.prefetch_timestamp = timestamp;
        context.state_machine.prefetch(
            TestContext.callback,
            op,
            operation,
            input,
        );
        while (context.busy) context.storage.tick();

        return context.state_machine.commit(
            0,
            1,
            timestamp,
            operation,
            input,
            output,
        );
    }
};

const TestAction = union(enum) {
    // Set the account's balance.
    setup: struct {
        account: u128,
        debits_pending: u128,
        debits_posted: u128,
        credits_pending: u128,
        credits_posted: u128,
    },

    tick: struct {
        value: i64,
        unit: enum { seconds },
    },

    commit: TestContext.StateMachine.Operation,
    account: TestCreateAccount,
    transfer: TestCreateTransfer,

    lookup_account: struct {
        id: u128,
        balance: ?struct {
            debits_pending: u128,
            debits_posted: u128,
            credits_pending: u128,
            credits_posted: u128,
        } = null,
    },
    lookup_transfer: struct {
        id: u128,
        data: union(enum) {
            exists: bool,
            amount: u128,
        },
    },

    get_account_balances: TestGetAccountBalances,
    get_account_balances_result: struct {
        transfer_id: u128,
        debits_pending: u128,
        debits_posted: u128,
        credits_pending: u128,
        credits_posted: u128,
    },

    get_account_transfers: TestGetAccountTransfers,
    get_account_transfers_result: TestGetAccountTransfersResult,

    query_accounts: TestQueryAccounts,
    query_accounts_result: u128,

    query_transfers: TestQueryTransfers,
    query_transfers_result: u128,
};

const TestCreateAccount = struct {
    id: u128,
    debits_pending: u128 = 0,
    debits_posted: u128 = 0,
    credits_pending: u128 = 0,
    credits_posted: u128 = 0,
    user_data_128: u128 = 0,
    user_data_64: u64 = 0,
    user_data_32: u32 = 0,
    reserved: u1 = 0,
    ledger: u32,
    code: u16,
    flags_linked: ?enum { LNK } = null,
    flags_debits_must_not_exceed_credits: ?enum { @"D<C" } = null,
    flags_credits_must_not_exceed_debits: ?enum { @"C<D" } = null,
    flags_history: ?enum { HIST } = null,
    flags_padding: u12 = 0,
    timestamp: u64 = 0,
    result: CreateAccountResult,

    fn event(a: TestCreateAccount, timestamp: ?u64) Account {
        return .{
            .id = a.id,
            .debits_pending = a.debits_pending,
            .debits_posted = a.debits_posted,
            .credits_pending = a.credits_pending,
            .credits_posted = a.credits_posted,
            .user_data_128 = a.user_data_128,
            .user_data_64 = a.user_data_64,
            .user_data_32 = a.user_data_32,
            .reserved = a.reserved,
            .ledger = a.ledger,
            .code = a.code,
            .flags = .{
                .linked = a.flags_linked != null,
                .debits_must_not_exceed_credits = a.flags_debits_must_not_exceed_credits != null,
                .credits_must_not_exceed_debits = a.flags_credits_must_not_exceed_debits != null,
                .history = a.flags_history != null,
                .padding = a.flags_padding,
            },
            .timestamp = timestamp orelse a.timestamp,
        };
    }
};

const TestCreateTransfer = struct {
    id: u128,
    debit_account_id: u128,
    credit_account_id: u128,
    amount: u128 = 0,
    pending_id: u128 = 0,
    user_data_128: u128 = 0,
    user_data_64: u64 = 0,
    user_data_32: u32 = 0,
    timeout: u32 = 0,
    ledger: u32,
    code: u16,
    flags_linked: ?enum { LNK } = null,
    flags_pending: ?enum { PEN } = null,
    flags_post_pending_transfer: ?enum { POS } = null,
    flags_void_pending_transfer: ?enum { VOI } = null,
    flags_balancing_debit: ?enum { BDR } = null,
    flags_balancing_credit: ?enum { BCR } = null,
    flags_padding: u7 = 0,
    timestamp: u64 = 0,
    result: CreateTransferResult,

    fn event(t: TestCreateTransfer, timestamp: ?u64) Transfer {
        return .{
            .id = t.id,
            .debit_account_id = t.debit_account_id,
            .credit_account_id = t.credit_account_id,
            .amount = t.amount,
            .pending_id = t.pending_id,
            .user_data_128 = t.user_data_128,
            .user_data_64 = t.user_data_64,
            .user_data_32 = t.user_data_32,
            .timeout = t.timeout,
            .ledger = t.ledger,
            .code = t.code,
            .flags = .{
                .linked = t.flags_linked != null,
                .pending = t.flags_pending != null,
                .post_pending_transfer = t.flags_post_pending_transfer != null,
                .void_pending_transfer = t.flags_void_pending_transfer != null,
                .balancing_debit = t.flags_balancing_debit != null,
                .balancing_credit = t.flags_balancing_credit != null,
                .padding = t.flags_padding,
            },
            .timestamp = timestamp orelse t.timestamp,
        };
    }
};

const TestAccountFilter = struct {
    account_id: u128,
    // When non-null, the filter is set to the timestamp at which the specified transfer (by id) was
    // created.
    timestamp_min_transfer_id: ?u128 = null,
    timestamp_max_transfer_id: ?u128 = null,
    limit: u32,
    flags_debits: ?enum { DR } = null,
    flags_credits: ?enum { CR } = null,
    flags_reversed: ?enum { REV } = null,
};

const TestQueryFilter = struct {
    user_data_128: u128,
    user_data_64: u64,
    user_data_32: u32,
    ledger: u32,
    code: u16,
    timestamp_min_transfer_id: ?u128 = null,
    timestamp_max_transfer_id: ?u128 = null,
    limit: u32,
    flags_reversed: ?enum { REV } = null,
};

// Operations that share the same input.
const TestGetAccountBalances = TestAccountFilter;
const TestGetAccountTransfers = TestAccountFilter;
const TestQueryAccounts = TestQueryFilter;
const TestQueryTransfers = TestQueryFilter;

const TestGetAccountTransfersResult = struct {
    id: u128,
    debit_account_id: u128,
    credit_account_id: u128,
    amount: u128 = 0,
    pending_id: u128 = 0,
    user_data_128: u128 = 0,
    user_data_64: u64 = 0,
    user_data_32: u32 = 0,
    timeout: u32 = 0,
    ledger: u32,
    code: u16,
    flags_linked: ?enum { LNK } = null,
    flags_pending: ?enum { PEN } = null,
    flags_post_pending_transfer: ?enum { POS } = null,
    flags_void_pending_transfer: ?enum { VOI } = null,
    flags_balancing_debit: ?enum { BDR } = null,
    flags_balancing_credit: ?enum { BCR } = null,
    flags_padding: u10 = 0,
    timestamp: u64 = 0,

    fn result(t: TestGetAccountTransfersResult, timestamp: ?u64) Transfer {
        return .{
            .id = t.id,
            .debit_account_id = t.debit_account_id,
            .credit_account_id = t.credit_account_id,
            .amount = t.amount,
            .pending_id = t.pending_id,
            .user_data_128 = t.user_data_128,
            .user_data_64 = t.user_data_64,
            .user_data_32 = t.user_data_32,
            .timeout = t.timeout,
            .ledger = t.ledger,
            .code = t.code,
            .flags = .{
                .linked = t.flags_linked != null,
                .pending = t.flags_pending != null,
                .post_pending_transfer = t.flags_post_pending_transfer != null,
                .void_pending_transfer = t.flags_void_pending_transfer != null,
                .balancing_debit = t.flags_balancing_debit != null,
                .balancing_credit = t.flags_balancing_credit != null,
                .padding = t.flags_padding,
            },
            .timestamp = timestamp orelse t.timestamp,
        };
    }
};

fn check(test_table: []const u8) !void {
    const parse_table = @import("testing/table.zig").parse;
    const allocator = std.testing.allocator;

    var context: TestContext = undefined;
    try context.init(allocator);
    defer context.deinit(allocator);

    var accounts = std.AutoHashMap(u128, Account).init(allocator);
    defer accounts.deinit();

    var transfers = std.AutoHashMap(u128, Transfer).init(allocator);
    defer transfers.deinit();

    var request = std.ArrayListAligned(u8, 16).init(allocator);
    defer request.deinit();

    var reply = std.ArrayListAligned(u8, 16).init(allocator);
    defer reply.deinit();

    var op: u64 = 1;
    var operation: ?TestContext.StateMachine.Operation = null;

    const test_actions = parse_table(TestAction, test_table);
    for (test_actions.const_slice()) |test_action| {
        switch (test_action) {
            .setup => |b| {
                assert(operation == null);

                const account = context.state_machine.forest.grooves.accounts.get(b.account).?;
                var account_new = account.*;

                account_new.debits_pending = b.debits_pending;
                account_new.debits_posted = b.debits_posted;
                account_new.credits_pending = b.credits_pending;
                account_new.credits_posted = b.credits_posted;
                if (!stdx.equal_bytes(Account, &account_new, account)) {
                    context.state_machine.forest.grooves.accounts.update(.{
                        .old = account,
                        .new = &account_new,
                    });
                }
            },

            .tick => |ticks| {
                assert(ticks.value != 0);
                const interval_ns: u64 = @abs(ticks.value) *
                    switch (ticks.unit) {
                    .seconds => std.time.ns_per_s,
                };

                // The `parse` logic already computes `maxInt - value` when a unsigned int is
                // represented as a negative number. However, we need to use a signed int and
                // perform our own calculation to account for the unit.
                context.state_machine.prepare_timestamp += if (ticks.value > 0)
                    interval_ns
                else
                    TimestampRange.timestamp_max - interval_ns;
            },

            .account => |a| {
                assert(operation == null or operation.? == .create_accounts);
                operation = .create_accounts;

                const event = a.event(null);
                try request.appendSlice(std.mem.asBytes(&event));
                if (a.result == .ok) {
                    const timestamp = context.state_machine.prepare_timestamp + 1 +
                        @divExact(request.items.len, @sizeOf(Account));
                    try accounts.put(a.id, a.event(if (a.timestamp == 0) timestamp else null));
                } else {
                    const result = CreateAccountsResult{
                        .index = @intCast(@divExact(request.items.len, @sizeOf(Account)) - 1),
                        .result = a.result,
                    };
                    try reply.appendSlice(std.mem.asBytes(&result));
                }
            },
            .transfer => |t| {
                assert(operation == null or operation.? == .create_transfers);
                operation = .create_transfers;

                const event = t.event(null);
                try request.appendSlice(std.mem.asBytes(&event));
                if (t.result == .ok) {
                    const timestamp = context.state_machine.prepare_timestamp + 1 +
                        @divExact(request.items.len, @sizeOf(Transfer));
                    try transfers.put(t.id, t.event(if (t.timestamp == 0) timestamp else null));
                } else {
                    const result = CreateTransfersResult{
                        .index = @intCast(@divExact(request.items.len, @sizeOf(Transfer)) - 1),
                        .result = t.result,
                    };
                    try reply.appendSlice(std.mem.asBytes(&result));
                }
            },
            .lookup_account => |a| {
                assert(operation == null or operation.? == .lookup_accounts);
                operation = .lookup_accounts;

                try request.appendSlice(std.mem.asBytes(&a.id));
                if (a.balance) |b| {
                    var account = accounts.get(a.id).?;
                    account.debits_pending = b.debits_pending;
                    account.debits_posted = b.debits_posted;
                    account.credits_pending = b.credits_pending;
                    account.credits_posted = b.credits_posted;
                    try reply.appendSlice(std.mem.asBytes(&account));
                }
            },
            .lookup_transfer => |t| {
                assert(operation == null or operation.? == .lookup_transfers);
                operation = .lookup_transfers;

                try request.appendSlice(std.mem.asBytes(&t.id));
                switch (t.data) {
                    .exists => |exists| {
                        if (exists) {
                            var transfer = transfers.get(t.id).?;
                            try reply.appendSlice(std.mem.asBytes(&transfer));
                        }
                    },
                    .amount => |amount| {
                        var transfer = transfers.get(t.id).?;
                        transfer.amount = amount;
                        try reply.appendSlice(std.mem.asBytes(&transfer));
                    },
                }
            },
            .get_account_balances => |f| {
                assert(operation == null or operation.? == .get_account_balances);
                operation = .get_account_balances;

                const timestamp_min =
                    if (f.timestamp_min_transfer_id) |id| transfers.get(id).?.timestamp else 0;
                const timestamp_max =
                    if (f.timestamp_max_transfer_id) |id| transfers.get(id).?.timestamp else 0;

                const event = AccountFilter{
                    .account_id = f.account_id,
                    .timestamp_min = timestamp_min,
                    .timestamp_max = timestamp_max,
                    .limit = f.limit,
                    .flags = .{
                        .debits = f.flags_debits != null,
                        .credits = f.flags_credits != null,
                        .reversed = f.flags_reversed != null,
                    },
                };
                try request.appendSlice(std.mem.asBytes(&event));
            },
            .get_account_balances_result => |r| {
                assert(operation.? == .get_account_balances);

                const balance = AccountBalance{
                    .debits_pending = r.debits_pending,
                    .debits_posted = r.debits_posted,
                    .credits_pending = r.credits_pending,
                    .credits_posted = r.credits_posted,
                    .timestamp = transfers.get(r.transfer_id).?.timestamp,
                };
                try reply.appendSlice(std.mem.asBytes(&balance));
            },
            .get_account_transfers => |f| {
                assert(operation == null or operation.? == .get_account_transfers);
                operation = .get_account_transfers;

                const timestamp_min =
                    if (f.timestamp_min_transfer_id) |id| transfers.get(id).?.timestamp else 0;
                const timestamp_max =
                    if (f.timestamp_max_transfer_id) |id| transfers.get(id).?.timestamp else 0;

                const event = AccountFilter{
                    .account_id = f.account_id,
                    .timestamp_min = timestamp_min,
                    .timestamp_max = timestamp_max,
                    .limit = f.limit,
                    .flags = .{
                        .debits = f.flags_debits != null,
                        .credits = f.flags_credits != null,
                        .reversed = f.flags_reversed != null,
                    },
                };
                try request.appendSlice(std.mem.asBytes(&event));
            },
            .get_account_transfers_result => |r| {
                assert(operation.? == .get_account_transfers);

                const transfer = r.result(transfers.get(r.id).?.timestamp);
                try reply.appendSlice(std.mem.asBytes(&transfer));
            },
            .query_accounts => |f| {
                assert(operation == null or operation.? == .query_accounts);
                operation = .query_accounts;

                const timestamp_min = if (f.timestamp_min_transfer_id) |id|
                    accounts.get(id).?.timestamp
                else
                    0;
                const timestamp_max = if (f.timestamp_max_transfer_id) |id|
                    accounts.get(id).?.timestamp
                else
                    0;

                const event = QueryFilter{
                    .user_data_128 = f.user_data_128,
                    .user_data_64 = f.user_data_64,
                    .user_data_32 = f.user_data_32,
                    .ledger = f.ledger,
                    .code = f.code,
                    .timestamp_min = timestamp_min,
                    .timestamp_max = timestamp_max,
                    .limit = f.limit,
                    .flags = .{
                        .reversed = f.flags_reversed != null,
                    },
                };
                try request.appendSlice(std.mem.asBytes(&event));
            },
            .query_accounts_result => |id| {
                assert(operation.? == .query_accounts);
                try reply.appendSlice(std.mem.asBytes(&accounts.get(id).?));
            },
            .query_transfers => |f| {
                assert(operation == null or operation.? == .query_transfers);
                operation = .query_transfers;

                const timestamp_min = if (f.timestamp_min_transfer_id) |id|
                    transfers.get(id).?.timestamp
                else
                    0;
                const timestamp_max = if (f.timestamp_max_transfer_id) |id|
                    transfers.get(id).?.timestamp
                else
                    0;

                const event = QueryFilter{
                    .user_data_128 = f.user_data_128,
                    .user_data_64 = f.user_data_64,
                    .user_data_32 = f.user_data_32,
                    .ledger = f.ledger,
                    .code = f.code,
                    .timestamp_min = timestamp_min,
                    .timestamp_max = timestamp_max,
                    .limit = f.limit,
                    .flags = .{
                        .reversed = f.flags_reversed != null,
                    },
                };
                try request.appendSlice(std.mem.asBytes(&event));
            },
            .query_transfers_result => |id| {
                assert(operation.? == .query_transfers);
                try reply.appendSlice(std.mem.asBytes(&transfers.get(id).?));
            },
            .commit => |commit_operation| {
                assert(operation == null or operation.? == commit_operation);
                assert(!context.busy);

                const reply_actual_buffer = try allocator.alignedAlloc(
                    u8,
                    16,
                    TestContext.message_body_size_max,
                );
                defer allocator.free(reply_actual_buffer);

                context.state_machine.prepare_timestamp += 1;
                context.state_machine.prepare(commit_operation, request.items);

                if (context.state_machine.pulse_needed(context.state_machine.prepare_timestamp)) {
                    const pulse_size = context.execute(
                        op,
                        vsr.Operation.pulse.cast(TestContext.StateMachine),
                        &.{},
                        reply_actual_buffer[0..TestContext.message_body_size_max],
                    );
                    assert(pulse_size == 0);

                    op += 1;
                }

                const reply_actual_size = context.execute(
                    op,
                    commit_operation,
                    request.items,
                    reply_actual_buffer[0..TestContext.message_body_size_max],
                );
                const reply_actual = reply_actual_buffer[0..reply_actual_size];

                switch (commit_operation) {
                    inline else => |commit_operation_comptime| {
                        const Result = TestContext.StateMachine.Result(commit_operation_comptime);
                        try testing.expectEqualSlices(
                            Result,
                            mem.bytesAsSlice(Result, reply.items),
                            mem.bytesAsSlice(Result, reply_actual),
                        );
                    },
                    .pulse => unreachable,
                }

                request.clearRetainingCapacity();
                reply.clearRetainingCapacity();
                operation = null;
                op += 1;
            },
        }
    }

    assert(operation == null);
    assert(request.items.len == 0);
    assert(reply.items.len == 0);
}

test "create_accounts" {
    try check(
        \\ account A1  0  0  0  0 U2 U2 U2 _ L3 C4 _   _   _ _ _ _ ok
        \\ account A0  1  1  1  1  _  _  _ 1 L0 C0 _ D<C C<D _ 1 1 timestamp_must_be_zero
        \\ account A0  1  1  1  1  _  _  _ 1 L0 C0 _ D<C C<D _ 1 _ reserved_field
        \\ account A0  1  1  1  1  _  _  _ _ L0 C0 _ D<C C<D _ 1 _ reserved_flag
        \\ account A0  1  1  1  1  _  _  _ _ L0 C0 _ D<C C<D _ _ _ id_must_not_be_zero
        \\ account -0  1  1  1  1  _  _  _ _ L0 C0 _ D<C C<D _ _ _ id_must_not_be_int_max
        \\ account A1  1  1  1  1 U1 U1 U1 _ L0 C0 _ D<C C<D _ _ _ flags_are_mutually_exclusive
        \\ account A1  1  1  1  1 U1 U1 U1 _ L9 C9 _ D<C   _ _ _ _ debits_pending_must_be_zero
        \\ account A1  0  1  1  1 U1 U1 U1 _ L9 C9 _ D<C   _ _ _ _ debits_posted_must_be_zero
        \\ account A1  0  0  1  1 U1 U1 U1 _ L9 C9 _ D<C   _ _ _ _ credits_pending_must_be_zero
        \\ account A1  0  0  0  1 U1 U1 U1 _ L9 C9 _ D<C   _ _ _ _ credits_posted_must_be_zero
        \\ account A1  0  0  0  0 U1 U1 U1 _ L0 C0 _ D<C   _ _ _ _ ledger_must_not_be_zero
        \\ account A1  0  0  0  0 U1 U1 U1 _ L9 C0 _ D<C   _ _ _ _ code_must_not_be_zero
        \\ account A1  0  0  0  0 U1 U1 U1 _ L9 C9 _ D<C   _ _ _ _ exists_with_different_flags
        \\ account A1  0  0  0  0 U1 U1 U1 _ L9 C9 _   _ C<D _ _ _ exists_with_different_flags
        \\ account A1  0  0  0  0 U1 U1 U1 _ L9 C9 _   _   _ _ _ _ exists_with_different_user_data_128
        \\ account A1  0  0  0  0 U2 U1 U1 _ L9 C9 _   _   _ _ _ _ exists_with_different_user_data_64
        \\ account A1  0  0  0  0 U2 U2 U1 _ L9 C9 _   _   _ _ _ _ exists_with_different_user_data_32
        \\ account A1  0  0  0  0 U2 U2 U2 _ L9 C9 _   _   _ _ _ _ exists_with_different_ledger
        \\ account A1  0  0  0  0 U2 U2 U2 _ L3 C9 _   _   _ _ _ _ exists_with_different_code
        \\ account A1  0  0  0  0 U2 U2 U2 _ L3 C4 _   _   _ _ _ _ exists
        \\ commit create_accounts
        \\
        \\ lookup_account -0 _
        \\ lookup_account A0 _
        \\ lookup_account A1 0 0 0 0
        \\ lookup_account A2 _
        \\ commit lookup_accounts
    );
}

test "create_accounts: empty" {
    try check(
        \\ commit create_transfers
    );
}

test "linked accounts" {
    try check(
        \\ account A7  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok // An individual event (successful):

        // A chain of 4 events (the last event in the chain closes the chain with linked=false):
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ linked_event_failed // Commit/rollback.
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ linked_event_failed // Commit/rollback.
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ exists              // Fail with .exists.
        \\ account A3  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ linked_event_failed // Fail without committing.

        // An individual event (successful):
        // This does not see any effect from the failed chain above.
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok

        // A chain of 2 events (the first event fails the chain):
        \\ account A1  0  0  0  0  _  _  _ _ L1 C2 LNK   _   _ _ _ _ exists_with_different_flags
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ linked_event_failed

        // An individual event (successful):
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok

        // A chain of 2 events (the last event fails the chain):
        \\ account A3  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ linked_event_failed
        \\ account A1  0  0  0  0  _  _  _ _ L2 C1   _   _   _ _ _ _ exists_with_different_ledger

        // A chain of 2 events (successful):
        \\ account A3  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ ok
        \\ account A4  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ commit create_accounts
        \\
        \\ lookup_account A7 0 0 0 0
        \\ lookup_account A1 0 0 0 0
        \\ lookup_account A2 0 0 0 0
        \\ lookup_account A3 0 0 0 0
        \\ lookup_account A4 0 0 0 0
        \\ commit lookup_accounts
    );

    try check(
        \\ account A7  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok // An individual event (successful):

        // A chain of 4 events:
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ linked_event_failed // Commit/rollback.
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ linked_event_failed // Commit/rollback.
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ exists              // Fail with .exists.
        \\ account A3  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ linked_event_failed // Fail without committing.
        \\ commit create_accounts
        \\
        \\ lookup_account A7 0 0 0 0
        \\ lookup_account A1 _
        \\ lookup_account A2 _
        \\ lookup_account A3 _
        \\ commit lookup_accounts
    );

    // TODO How can we test that events were in fact rolled back in LIFO order?
    // All our rollback handlers appear to be commutative.
}

test "linked_event_chain_open" {
    try check(
    // A chain of 3 events (the last event in the chain closes the chain with linked=false):
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ ok
        \\ account A3  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok

        // An open chain of 2 events:
        \\ account A4  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ linked_event_failed
        \\ account A5  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ linked_event_chain_open
        \\ commit create_accounts
        \\
        \\ lookup_account A1 0 0 0 0
        \\ lookup_account A2 0 0 0 0
        \\ lookup_account A3 0 0 0 0
        \\ lookup_account A4 _
        \\ lookup_account A5 _
        \\ commit lookup_accounts
    );
}

test "linked_event_chain_open for an already failed batch" {
    try check(
    // An individual event (successful):
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok

        // An open chain of 3 events (the second one fails):
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ linked_event_failed
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ exists_with_different_flags
        \\ account A3  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ linked_event_chain_open
        \\ commit create_accounts
        \\
        \\ lookup_account A1 0 0 0 0
        \\ lookup_account A2 _
        \\ lookup_account A3 _
        \\ commit lookup_accounts
    );
}

test "linked_event_chain_open for a batch of 1" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1 LNK   _   _ _ _ _ linked_event_chain_open
        \\ commit create_accounts
        \\
        \\ lookup_account A1 _
        \\ commit lookup_accounts
    );
}

// The goal is to ensure that:
// 1. all CreateTransferResult enums are covered, with
// 2. enums tested in the order that they are defined, for easier auditing of coverage, and that
// 3. state machine logic cannot be reordered in any way, breaking determinism.
test "create_transfers/lookup_transfers" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L2 C2   _   _   _ _ _ _ ok
        \\ account A3  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ account A4  0  0  0  0  _  _  _ _ L1 C1   _ D<C   _ _ _ _ ok
        \\ account A5  0  0  0  0  _  _  _ _ L1 C1   _   _ C<D _ _ _ ok
        \\ commit create_accounts

        // Set up initial balances.
        \\ setup A1  100   200    0     0
        \\ setup A2    0     0    0     0
        \\ setup A3    0     0  110   210
        \\ setup A4   20  -700    0  -500
        \\ setup A5    0 -1000   10 -1100

        // Bump the state machine time to `maxInt - 3s` for testing timeout overflow.
        \\ tick -3 seconds

        // Test errors by descending precedence.
        \\ transfer   T0 A0 A0    0  T1  _  _  _    _ L0 C0   _ PEN   _   _   _   _ P1 1 timestamp_must_be_zero
        \\ transfer   T0 A0 A0    0  T1  _  _  _    _ L0 C0   _ PEN   _   _   _   _ P1 _ reserved_flag
        \\ transfer   T0 A0 A0    0  T1  _  _  _    _ L0 C0   _ PEN   _   _   _   _  _ _ id_must_not_be_zero
        \\ transfer   -0 A0 A0    0  T1  _  _  _    _ L0 C0   _ PEN   _   _   _   _  _ _ id_must_not_be_int_max
        \\ transfer   T1 A0 A0    0  T1  _  _  _    _ L0 C0   _ PEN   _   _   _   _  _ _ debit_account_id_must_not_be_zero
        \\ transfer   T1 -0 A0    0  T1  _  _  _    _ L0 C0   _ PEN   _   _   _   _  _ _ debit_account_id_must_not_be_int_max
        \\ transfer   T1 A8 A0    0  T1  _  _  _    _ L0 C0   _ PEN   _   _   _   _  _ _ credit_account_id_must_not_be_zero
        \\ transfer   T1 A8 -0    0  T1  _  _  _    _ L0 C0   _ PEN   _   _   _   _  _ _ credit_account_id_must_not_be_int_max
        \\ transfer   T1 A8 A8    0  T1  _  _  _    _ L0 C0   _ PEN   _   _   _   _  _ _ accounts_must_be_different
        \\ transfer   T1 A8 A9    0  T1  _  _  _    _ L0 C0   _ PEN   _   _   _   _  _ _ pending_id_must_be_zero
        \\ transfer   T1 A8 A9    0   _  _  _  _    1 L0 C0   _   _   _   _   _   _  _ _ timeout_reserved_for_pending_transfer
        \\ transfer   T1 A8 A9    0   _  _  _  _    _ L0 C0   _ PEN   _   _   _   _  _ _ amount_must_not_be_zero
        \\ transfer   T1 A8 A9    9   _  _  _  _    _ L0 C0   _ PEN   _   _   _   _  _ _ ledger_must_not_be_zero
        \\ transfer   T1 A8 A9    9   _  _  _  _    _ L9 C0   _ PEN   _   _   _   _  _ _ code_must_not_be_zero
        \\ transfer   T1 A8 A9    9   _  _  _  _    _ L9 C1   _ PEN   _   _   _   _  _ _ debit_account_not_found
        \\ transfer   T1 A1 A9    9   _  _  _  _    _ L9 C1   _ PEN   _   _   _   _  _ _ credit_account_not_found
        \\ transfer   T1 A1 A2    1   _  _  _  _    _ L9 C1   _ PEN   _   _   _   _  _ _ accounts_must_have_the_same_ledger
        \\ transfer   T1 A1 A3    1   _  _  _  _    _ L9 C1   _ PEN   _   _   _   _  _ _ transfer_must_have_the_same_ledger_as_accounts
        \\ transfer   T1 A1 A3  -99   _  _  _  _    _ L1 C1   _ PEN   _   _   _   _  _ _ overflows_debits_pending  // amount = max - A1.debits_pending + 1
        \\ transfer   T1 A1 A3 -109   _  _  _  _    _ L1 C1   _ PEN   _   _   _   _  _ _ overflows_credits_pending // amount = max - A3.credits_pending + 1
        \\ transfer   T1 A1 A3 -199   _  _  _  _    _ L1 C1   _ PEN   _   _   _   _  _ _ overflows_debits_posted   // amount = max - A1.debits_posted + 1
        \\ transfer   T1 A1 A3 -209   _  _  _  _    _ L1 C1   _ PEN   _   _   _   _  _ _ overflows_credits_posted  // amount = max - A3.credits_posted + 1
        \\ transfer   T1 A1 A3 -299   _  _  _  _    _ L1 C1   _ PEN   _   _   _   _  _ _ overflows_debits          // amount = max - A1.debits_pending - A1.debits_posted + 1
        \\ transfer   T1 A1 A3 -319   _  _  _  _    _ L1 C1   _ PEN   _   _   _   _  _ _ overflows_credits         // amount = max - A3.credits_pending - A3.credits_posted + 1
        \\ transfer   T1 A4 A5  199   _  _  _  _  999 L1 C1   _ PEN   _   _   _   _  _ _ overflows_timeout
        \\ transfer   T1 A4 A5  199   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ exceeds_credits           // amount = A4.credits_posted - A4.debits_pending - A4.debits_posted + 1
        \\ transfer   T1 A4 A5   91   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ exceeds_debits            // amount = A5.debits_posted - A5.credits_pending - A5.credits_posted + 1
        \\ transfer   T1 A1 A3  123   _  _  _  _    1 L1 C1   _ PEN   _   _   _   _  _ _ ok

        // Ensure that idempotence is only checked after validation.
        \\ transfer   T1 A1 A3  123   _  _  _  _    1 L2 C1   _ PEN   _   _   _   _  _ _ transfer_must_have_the_same_ledger_as_accounts
        \\ transfer   T1 A1 A3   -0   _ U1 U1 U1    _ L1 C2   _   _   _   _   _   _  _ _ exists_with_different_flags
        \\ transfer   T1 A3 A1   -0   _ U1 U1 U1    1 L1 C2   _ PEN   _   _   _   _  _ _ exists_with_different_debit_account_id
        \\ transfer   T1 A1 A4   -0   _ U1 U1 U1    1 L1 C2   _ PEN   _   _   _   _  _ _ exists_with_different_credit_account_id
        \\ transfer   T1 A1 A3   -0   _ U1 U1 U1    1 L1 C1   _ PEN   _   _   _   _  _ _ exists_with_different_amount
        \\ transfer   T1 A1 A3  123   _ U1 U1 U1    1 L1 C2   _ PEN   _   _   _   _  _ _ exists_with_different_user_data_128
        \\ transfer   T1 A1 A3  123   _  _ U1 U1    1 L1 C2   _ PEN   _   _   _   _  _ _ exists_with_different_user_data_64
        \\ transfer   T1 A1 A3  123   _  _  _ U1    1 L1 C2   _ PEN   _   _   _   _  _ _ exists_with_different_user_data_32
        \\ transfer   T1 A1 A3  123   _  _  _  _    2 L1 C2   _ PEN   _   _   _   _  _ _ exists_with_different_timeout
        \\ transfer   T1 A1 A3  123   _  _  _  _    1 L1 C2   _ PEN   _   _   _   _  _ _ exists_with_different_code
        \\ transfer   T1 A1 A3  123   _  _  _  _    1 L1 C1   _ PEN   _   _   _   _  _ _ exists
        \\ transfer   T2 A3 A1    7   _  _  _  _    _ L1 C2   _   _   _   _   _   _  _ _ ok
        \\ transfer   T3 A1 A3    3   _  _  _  _    _ L1 C2   _   _   _   _   _   _  _ _ ok
        \\ commit create_transfers
        \\
        \\ lookup_account A1 223 203   0   7
        \\ lookup_account A3   0   7 233 213
        \\ commit lookup_accounts
        \\
        \\ lookup_transfer T1 exists true
        \\ lookup_transfer T2 exists true
        \\ lookup_transfer T3 exists true
        \\ lookup_transfer -0 exists false
        \\ commit lookup_transfers
    );
}

test "create/lookup 2-phase transfers" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ commit create_accounts

        // First phase.
        \\ transfer   T1 A1 A2   15   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ ok // Not pending!
        \\ transfer   T2 A1 A2   15   _  _  _  _ 1000 L1 C1   _ PEN   _   _   _   _  _ _ ok
        \\ transfer   T3 A1 A2   15   _  _  _  _   50 L1 C1   _ PEN   _   _   _   _  _ _ ok
        \\ transfer   T4 A1 A2   15   _  _  _  _    1 L1 C1   _ PEN   _   _   _   _  _ _ ok
        \\ transfer   T5 A1 A2    7   _ U9 U9 U9   50 L1 C1   _ PEN   _   _   _   _  _ _ ok
        \\ transfer   T6 A1 A2    1   _  _  _  _    0 L1 C1   _ PEN   _   _   _   _  _ _ ok
        \\ commit create_transfers

        // Check balances before resolving.
        \\ lookup_account A1 53 15  0  0
        \\ lookup_account A2  0  0 53 15
        \\ commit lookup_accounts

        // Bump the state machine time in +1s for testing the timeout expiration.
        \\ tick 1 seconds

        // Second phase.
        \\ transfer T101 A1 A2   13  T2 U1 U1 U1    _ L1 C1   _   _ POS   _   _   _  _ _ ok
        \\ transfer   T0 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _ PEN POS VOI   _   _  _ 1 timestamp_must_be_zero
        \\ transfer   T0 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _ PEN POS VOI   _   _  _ _ id_must_not_be_zero
        \\ transfer   -0 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _ PEN POS VOI   _   _  _ _ id_must_not_be_int_max
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _ PEN POS VOI   _   _  _ _ flags_are_mutually_exclusive
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _ PEN POS VOI BDR   _  _ _ flags_are_mutually_exclusive
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _ PEN POS VOI BDR BCR  _ _ flags_are_mutually_exclusive
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _ PEN POS VOI   _ BCR  _ _ flags_are_mutually_exclusive
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _ PEN   _ VOI   _   _  _ _ flags_are_mutually_exclusive
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _   _   _ VOI BDR   _  _ _ flags_are_mutually_exclusive
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _   _   _ VOI BDR BCR  _ _ flags_are_mutually_exclusive
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _   _   _ VOI   _ BCR  _ _ flags_are_mutually_exclusive
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _   _ POS   _ BDR   _  _ _ flags_are_mutually_exclusive
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _   _ POS   _ BDR BCR  _ _ flags_are_mutually_exclusive
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _   _ POS   _   _ BCR  _ _ flags_are_mutually_exclusive
        \\ transfer T101 A8 A9   16  T0 U2 U2 U2   50 L6 C7   _   _   _ VOI   _   _  _ _ pending_id_must_not_be_zero
        \\ transfer T101 A8 A9   16  -0 U2 U2 U2   50 L6 C7   _   _   _ VOI   _   _  _ _ pending_id_must_not_be_int_max
        \\ transfer T101 A8 A9   16 101 U2 U2 U2   50 L6 C7   _   _   _ VOI   _   _  _ _ pending_id_must_be_different
        \\ transfer T101 A8 A9   16 102 U2 U2 U2   50 L6 C7   _   _   _ VOI   _   _  _ _ timeout_reserved_for_pending_transfer
        \\ transfer T101 A8 A9   16 102 U2 U2 U2    _ L6 C7   _   _   _ VOI   _   _  _ _ pending_transfer_not_found
        \\ transfer T101 A8 A9   16  T1 U2 U2 U2    _ L6 C7   _   _   _ VOI   _   _  _ _ pending_transfer_not_pending
        \\ transfer T101 A8 A9   16  T3 U2 U2 U2    _ L6 C7   _   _   _ VOI   _   _  _ _ pending_transfer_has_different_debit_account_id
        \\ transfer T101 A1 A9   16  T3 U2 U2 U2    _ L6 C7   _   _   _ VOI   _   _  _ _ pending_transfer_has_different_credit_account_id
        \\ transfer T101 A1 A2   16  T3 U2 U2 U2    _ L6 C7   _   _   _ VOI   _   _  _ _ pending_transfer_has_different_ledger
        \\ transfer T101 A1 A2   16  T3 U2 U2 U2    _ L1 C7   _   _   _ VOI   _   _  _ _ pending_transfer_has_different_code
        \\ transfer T101 A1 A2   16  T3 U2 U2 U2    _ L1 C1   _   _   _ VOI   _   _  _ _ exceeds_pending_transfer_amount
        \\ transfer T101 A1 A2   14  T3 U2 U2 U2    _ L1 C1   _   _   _ VOI   _   _  _ _ pending_transfer_has_different_amount
        \\ transfer T101 A1 A2   15  T3 U2 U2 U2    _ L1 C1   _   _   _ VOI   _   _  _ _ exists_with_different_flags
        \\ transfer T101 A1 A2   14  T2 U1 U1 U1    _ L1 C1   _   _ POS   _   _   _  _ _ exists_with_different_amount
        \\ transfer T101 A1 A2    _  T2 U1 U1 U1    _ L1 C1   _   _ POS   _   _   _  _ _ exists_with_different_amount
        \\ transfer T101 A1 A2   13  T3 U2 U2 U2    _ L1 C1   _   _ POS   _   _   _  _ _ exists_with_different_pending_id
        \\ transfer T101 A1 A2   13  T2 U2 U2 U2    _ L1 C1   _   _ POS   _   _   _  _ _ exists_with_different_user_data_128
        \\ transfer T101 A1 A2   13  T2 U1 U2 U2    _ L1 C1   _   _ POS   _   _   _  _ _ exists_with_different_user_data_64
        \\ transfer T101 A1 A2   13  T2 U1 U1 U2    _ L1 C1   _   _ POS   _   _   _  _ _ exists_with_different_user_data_32
        \\ transfer T101 A1 A2   13  T2 U1 U1 U1    _ L1 C1   _   _ POS   _   _   _  _ _ exists
        \\ transfer T102 A1 A2   13  T2 U1 U1 U1    _ L1 C1   _   _ POS   _   _   _  _ _ pending_transfer_already_posted
        \\ transfer T103 A1 A2   15  T3 U1 U1 U1    _ L1 C1   _   _   _ VOI   _   _  _ _ ok
        \\ transfer T102 A1 A2   13  T3 U1 U1 U1    _ L1 C1   _   _ POS   _   _   _  _ _ pending_transfer_already_voided
        \\ transfer T102 A1 A2   15  T4 U1 U1 U1    _ L1 C1   _   _   _ VOI   _   _  _ _ pending_transfer_expired

        // Transfers posted/voided with optional fields must not raise `exists_with_different_*`.
        \\ transfer T105 A0 A0    _  T5 U0 U0 U0    _ L0 C0   _   _ POS   _   _   _  _ _ ok
        \\ transfer T105 A0 A0    _  T5 U0 U0 U0    _ L0 C0   _   _ POS   _   _   _  _ _ exists
        \\ transfer T105 A0 A0    7  T5 U0 U0 U0    _ L1 C1   _   _ POS   _   _   _  _ _ exists
        \\ transfer T106 A0 A0    0  T6 U0 U0 U0    _ L1 C1   _   _ POS   _   _   _  _ _ ok
        \\ transfer T106 A0 A0    0  T6 U0 U0 U0    _ L1 C1   _   _ POS   _   _   _  _ _ exists
        \\ transfer T106 A0 A0    0  T6 U0 U0 U0    _ L1 C1   _   _ POS   _   _   _  _ _ exists
        \\ transfer T106 A0 A0    1  T6 U0 U0 U0    _ L0 C0   _   _ POS   _   _   _  _ _ exists
        \\ commit create_transfers

        // Check balances after resolving.
        \\ lookup_account A1  0 36  0  0
        \\ lookup_account A2  0  0  0 36
        \\ commit lookup_accounts
    );
}

test "create/lookup expired transfers" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ commit create_accounts

        // First phase.
        \\ transfer   T1 A1 A2   10   _  _  _  _    0 L1 C1   _ PEN   _   _   _   _  _ _ ok // Timeout zero will never expire.
        \\ transfer   T2 A1 A2   11   _  _  _  _    1 L1 C1   _ PEN   _   _   _   _  _ _ ok
        \\ transfer   T3 A1 A2   12   _  _  _  _    2 L1 C1   _ PEN   _   _   _   _  _ _ ok
        \\ transfer   T4 A1 A2   13   _  _  _  _    3 L1 C1   _ PEN   _   _   _   _  _ _ ok
        \\ commit create_transfers

        // Check balances before expiration.
        \\ lookup_account A1 46  0  0  0
        \\ lookup_account A2  0  0 46  0
        \\ commit lookup_accounts

        // Check balances after 1s.
        \\ tick 1 seconds
        \\ lookup_account A1 35  0  0  0
        \\ lookup_account A2  0  0 35  0
        \\ commit lookup_accounts

        // Check balances after 1s.
        \\ tick 1 seconds
        \\ lookup_account A1 23  0  0  0
        \\ lookup_account A2  0  0 23  0
        \\ commit lookup_accounts

        // Check balances after 1s.
        \\ tick 1 seconds
        \\ lookup_account A1 10  0  0  0
        \\ lookup_account A2  0  0 10  0
        \\ commit lookup_accounts

        // Second phase.
        \\ transfer T101 A1 A2   10  T1 U1 U1 U1    _ L1 C1   _   _ POS   _   _   _  _ _ ok
        \\ transfer T102 A1 A2   11  T2 U1 U1 U1    _ L1 C1   _   _ POS   _   _   _  _ _ pending_transfer_expired
        \\ transfer T103 A1 A2   12  T3 U1 U1 U1    _ L1 C1   _   _ POS   _   _   _  _ _ pending_transfer_expired
        \\ transfer T104 A1 A2   13  T4 U1 U1 U1    _ L1 C1   _   _ POS   _   _   _  _ _ pending_transfer_expired
        \\ commit create_transfers

        // Check final balances.
        \\ lookup_account A1  0 10  0  0
        \\ lookup_account A2  0  0  0 10
        \\ commit lookup_accounts

        // Check transfers.
        \\ lookup_transfer T101 exists true
        \\ lookup_transfer T102 exists false
        \\ lookup_transfer T103 exists false
        \\ lookup_transfer T104 exists false
        \\ commit lookup_transfers
    );
}

test "create_transfers: empty" {
    try check(
        \\ commit create_transfers
    );
}

test "create_transfers/lookup_transfers: failed transfer does not exist" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ commit create_accounts
        \\
        \\ transfer   T1 A1 A2   15   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ ok
        \\ transfer   T2 A1 A2   15   _  _  _  _    _ L0 C1   _   _   _   _   _   _  _ _ ledger_must_not_be_zero
        \\ commit create_transfers
        \\
        \\ lookup_account A1 0 15 0  0
        \\ lookup_account A2 0  0 0 15
        \\ commit lookup_accounts
        \\
        \\ lookup_transfer T1 exists true
        \\ lookup_transfer T2 exists false
        \\ commit lookup_transfers
    );
}

test "create_transfers: failed linked-chains are undone" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ commit create_accounts
        \\
        \\ transfer   T1 A1 A2   15   _  _  _  _    _ L1 C1 LNK   _   _   _   _   _  _ _ linked_event_failed
        \\ transfer   T2 A1 A2   15   _  _  _  _    _ L0 C1   _   _   _   _   _   _  _ _ ledger_must_not_be_zero
        \\ commit create_transfers
        \\
        \\ transfer   T3 A1 A2   15   _  _  _  _    1 L1 C1 LNK PEN   _   _   _   _  _ _ linked_event_failed
        \\ transfer   T4 A1 A2   15   _  _  _  _    _ L0 C1   _   _   _   _   _   _  _ _ ledger_must_not_be_zero
        \\ commit create_transfers
        \\
        \\ lookup_account A1 0 0 0 0
        \\ lookup_account A2 0 0 0 0
        \\ commit lookup_accounts
        \\
        \\ lookup_transfer T1 exists false
        \\ lookup_transfer T2 exists false
        \\ lookup_transfer T3 exists false
        \\ lookup_transfer T4 exists false
        \\ commit lookup_transfers
    );
}

test "create_transfers: failed linked-chains are undone within a commit" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _ D<C   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ commit create_accounts
        \\
        \\ setup A1 0 0 0 20
        \\
        \\ transfer   T1 A1 A2   15   _ _   _  _    _ L1 C1 LNK   _   _   _   _   _  _ _ linked_event_failed
        \\ transfer   T2 A1 A2    5   _ _   _  _    _ L0 C1   _   _   _   _   _   _  _ _ ledger_must_not_be_zero
        \\ transfer   T3 A1 A2   15   _ _   _  _    _ L1 C1   _   _   _   _   _   _  _ _ ok
        \\ commit create_transfers
        \\
        \\ lookup_account A1 0 15 0 20
        \\ lookup_account A2 0  0 0 15
        \\ commit lookup_accounts
        \\
        \\ lookup_transfer T1 exists false
        \\ lookup_transfer T2 exists false
        \\ lookup_transfer T3 exists true
        \\ commit lookup_transfers
    );
}

test "create_transfers: balancing_debit | balancing_credit (*_must_not_exceed_*)" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _ D<C   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _ C<D _ _ _ ok
        \\ account A3  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ commit create_accounts
        \\
        \\ setup A1 1  0 0 10
        \\ setup A2 0 10 2  0
        \\
        \\ transfer   T1 A1 A3  3     _  _  _  _    _ L2 C1   _   _   _   _ BDR   _  _ _ transfer_must_have_the_same_ledger_as_accounts
        \\ transfer   T1 A3 A2  3     _  _  _  _    _ L2 C1   _   _   _   _   _ BCR  _ _ transfer_must_have_the_same_ledger_as_accounts
        \\ transfer   T1 A1 A3  3     _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ ok
        \\ transfer   T2 A1 A3 13     _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ ok
        \\ transfer   T3 A3 A2  3     _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ ok
        \\ transfer   T4 A3 A2 13     _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ ok
        \\ transfer   T5 A1 A3  1     _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ exceeds_credits
        \\ transfer   T5 A1 A3  1     _  _  _  _    _ L1 C1   _   _   _   _ BDR BCR  _ _ exceeds_credits
        \\ transfer   T5 A3 A2  1     _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ exceeds_debits
        \\ transfer   T5 A1 A2  1     _  _  _  _    _ L1 C1   _   _   _   _ BDR BCR  _ _ exceeds_credits
        \\ transfer   T1 A1 A3    2   _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ exists_with_different_amount
        \\ transfer   T1 A1 A3    0   _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ exists
        \\ transfer   T1 A1 A3    3   _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ exists
        \\ transfer   T1 A1 A3    4   _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ exists
        \\ transfer   T2 A1 A3    6   _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ exists
        \\ transfer   T2 A1 A3    0   _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ exists
        \\ transfer   T3 A3 A2    2   _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ exists_with_different_amount
        \\ transfer   T3 A3 A2    0   _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ exists
        \\ transfer   T3 A3 A2    3   _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ exists
        \\ transfer   T3 A3 A2    4   _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ exists
        \\ transfer   T4 A3 A2    5   _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ exists
        \\ transfer   T4 A3 A2    0   _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ exists
        \\ commit create_transfers
        \\
        \\ lookup_account A1 1  9 0 10
        \\ lookup_account A2 0 10 2  8
        \\ lookup_account A3 0  8 0  9
        \\ commit lookup_accounts
        \\
        \\ lookup_transfer T1 amount 3
        \\ lookup_transfer T2 amount 6
        \\ lookup_transfer T3 amount 3
        \\ lookup_transfer T4 amount 5
        \\ lookup_transfer T5 exists false
        \\ commit lookup_transfers
    );
}

test "create_transfers: balancing_debit | balancing_credit (¬*_must_not_exceed_*)" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ account A3  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ commit create_accounts
        \\
        \\ setup A1 1  0 0 10
        \\ setup A2 0 10 2  0
        \\
        \\ transfer   T1 A3 A1   99   _  _  _  _    _ L1 C1   _   _   _   _ BDR BCR  _ _ exceeds_credits
        \\ transfer   T1 A3 A1   99   _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ exceeds_credits
        \\ transfer   T1 A2 A3   99   _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ exceeds_debits
        \\ transfer   T1 A1 A3   99   _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ ok
        \\ transfer   T2 A1 A3   99   _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ exceeds_credits
        \\ transfer   T3 A3 A2   99   _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ ok
        \\ transfer   T4 A3 A2   99   _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ exceeds_debits
        \\ commit create_transfers
        \\
        \\ lookup_account A1 1  9 0 10
        \\ lookup_account A2 0 10 2  8
        \\ lookup_account A3 0  8 0  9
        \\ commit lookup_accounts
        \\
        \\ lookup_transfer T1 amount 9
        \\ lookup_transfer T2 exists false
        \\ lookup_transfer T3 amount 8
        \\ lookup_transfer T4 exists false
        \\ commit lookup_transfers
    );
}

test "create_transfers: balancing_debit | balancing_credit (amount=0)" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _ D<C   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _ C<D _ _ _ ok
        \\ account A3  0  0  0  0  _  _  _ _ L1 C1   _   _ C<D _ _ _ ok
        \\ account A4  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ commit create_accounts
        \\
        \\ setup A1 1  0 0 10
        \\ setup A2 0 10 2  0
        \\ setup A3 0 10 2  0
        \\
        \\ transfer   T1 A1 A4    0   _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ ok
        \\ transfer   T1 A1 A4    0   _  _  _  _    _ L1 C1   _   _   _   _ BDR   _  _ _ exists
        \\ transfer   T2 A4 A2    0   _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ ok
        \\ transfer   T2 A4 A2    0   _  _  _  _    _ L1 C1   _   _   _   _   _ BCR  _ _ exists
        \\ transfer   T3 A4 A3    0   _  _  _  _    _ L1 C1   _ PEN   _   _   _ BCR  _ _ ok
        \\ transfer   T3 A4 A3    0   _  _  _  _    _ L1 C1   _ PEN   _   _   _ BCR  _ _ exists
        \\ commit create_transfers
        \\
        \\ lookup_account A1 1  9  0 10
        \\ lookup_account A2 0 10  2  8
        \\ lookup_account A3 0 10 10  0
        \\ lookup_account A4 8  8  0  9
        \\ commit lookup_accounts
        \\
        \\ lookup_transfer T1 amount 9
        \\ lookup_transfer T2 amount 8
        \\ lookup_transfer T3 amount 8
        \\ commit lookup_transfers
    );
}

test "create_transfers: balancing_debit & balancing_credit" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _ D<C   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _ C<D _ _ _ ok
        \\ account A3  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ commit create_accounts
        \\
        \\ setup A1 0  0 0 20
        \\ setup A2 0 10 0  0
        \\ setup A3 0 99 0  0
        \\
        \\ transfer   T1 A1 A2    1   _  _  _  _    _ L1 C1   _   _   _   _ BDR BCR  _ _ ok
        \\ transfer   T2 A1 A2   12   _  _  _  _    _ L1 C1   _   _   _   _ BDR BCR  _ _ ok
        \\ transfer   T3 A1 A2    1   _  _  _  _    _ L1 C1   _   _   _   _ BDR BCR  _ _ exceeds_debits
        \\ transfer   T3 A1 A3   12   _  _  _  _    _ L1 C1   _   _   _   _ BDR BCR  _ _ ok
        \\ transfer   T4 A1 A3    1   _  _  _  _    _ L1 C1   _   _   _   _ BDR BCR  _ _ exceeds_credits
        \\ commit create_transfers
        \\
        \\ lookup_account A1 0 20 0 20
        \\ lookup_account A2 0 10 0 10
        \\ lookup_account A3 0 99 0 10
        \\ commit lookup_accounts
        \\
        \\ lookup_transfer T1 amount  1
        \\ lookup_transfer T2 amount  9
        \\ lookup_transfer T3 amount 10
        \\ lookup_transfer T4 exists false
        \\ commit lookup_transfers
    );
}

test "create_transfers: balancing_debit/balancing_credit + pending" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _ D<C   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _ C<D _ _ _ ok
        \\ commit create_accounts
        \\
        \\ setup A1 0  0 0 10
        \\ setup A2 0 10 0  0
        \\
        \\ transfer   T1 A1 A2    3   _  _  _  _    _ L1 C1   _ PEN   _   _ BDR   _  _ _ ok
        \\ transfer   T2 A1 A2   13   _  _  _  _    _ L1 C1   _ PEN   _   _ BDR   _  _ _ ok
        \\ transfer   T3 A1 A2    1   _  _  _  _    _ L1 C1   _ PEN   _   _ BDR   _  _ _ exceeds_credits
        \\ commit create_transfers
        \\
        \\ lookup_account A1 10  0  0 10
        \\ lookup_account A2  0 10 10  0
        \\ commit lookup_accounts
        \\
        \\ transfer   T3 A1 A2    0  T1  _  _  _    _ L1 C1   _   _ POS   _   _   _  _ _ ok
        \\ transfer   T4 A1 A2    5  T2  _  _  _    _ L1 C1   _   _ POS   _   _   _  _ _ ok
        \\ commit create_transfers
        \\
        \\ lookup_transfer T1 amount  3
        \\ lookup_transfer T2 amount  7
        \\ lookup_transfer T3 amount  3
        \\ lookup_transfer T4 amount  5
        \\ commit lookup_transfers
    );
}

test "get_account_transfers: single-phase" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _ _ _ HIST _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _ _ _ HIST _ _ ok
        \\ commit create_accounts
        \\
        \\ transfer T1 A1 A2   10   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ ok
        \\ transfer T2 A2 A1   11   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ ok
        \\ transfer T3 A1 A2   12   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ ok
        \\ transfer T4 A2 A1   13   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ ok
        \\ commit create_transfers
        \\
        \\ get_account_transfers A1 _ _ 10 DR CR  _ // Debits + credits, chronological.
        \\ get_account_transfers_result T1 A1 A2   10   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T2 A2 A1   11   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T3 A1 A2   12   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T4 A2 A1   13   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ commit get_account_transfers
        \\
        \\ get_account_transfers A1  _  _  2 DR CR  _ // Debits + credits, limit=2.
        \\ get_account_transfers_result T1 A1 A2   10   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T2 A2 A1   11   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ commit get_account_transfers
        \\
        \\ get_account_transfers A1 T3  _ 10 DR CR  _ // Debits + credits, timestamp_min>0.
        \\ get_account_transfers_result T3 A1 A2   12   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T4 A2 A1   13   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ commit get_account_transfers
        \\
        \\ get_account_transfers A1  _ T2 10 DR CR  _ // Debits + credits, timestamp_max>0.
        \\ get_account_transfers_result T1 A1 A2   10   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T2 A2 A1   11   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ commit get_account_transfers
        \\
        \\ get_account_transfers A1 T2 T3 10 DR CR  _ // Debits + credits, 0 < timestamp_min ≤ timestamp_max.
        \\ get_account_transfers_result T2 A2 A1   11   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T3 A1 A2   12   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ commit get_account_transfers
        \\
        \\ get_account_transfers A1  _  _ 10 DR CR REV // Debits + credits, reverse-chronological.
        \\ get_account_transfers_result T4 A2 A1   13   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T3 A1 A2   12   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T2 A2 A1   11   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T1 A1 A2   10   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ commit get_account_transfers
        \\
        \\ get_account_transfers A1  _  _ 10 DR  _  _ // Debits only.
        \\ get_account_transfers_result T1 A1 A2   10   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T3 A1 A2   12   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ commit get_account_transfers
        \\
        \\ get_account_transfers A1  _  _ 10  _ CR  _ // Credits only.
        \\ get_account_transfers_result T2 A2 A1   11   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ get_account_transfers_result T4 A2 A1   13   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _
        \\ commit get_account_transfers
    );
}

test "get_account_transfers: two-phase" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _ _ _ HIST _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _ _ _ HIST _ _ ok
        \\ commit create_accounts
        \\
        \\ transfer T1 A1 A2    2   _  _  _  _    0 L1 C1   _ PEN   _   _   _   _  _ _ ok
        \\ transfer T2 A1 A2    1  T1  _  _  _    0 L1 C1   _   _ POS   _   _   _  _ _ ok
        \\ commit create_transfers
        \\
        \\ get_account_transfers A1 _ _ 10 DR CR  _
        \\ get_account_transfers_result T1 A1 A2    2   _  _  _  _    0 L1 C1   _ PEN   _   _   _   _  _ _
        \\ get_account_transfers_result T2 A1 A2    1  T1  _  _  _    0 L1 C1   _   _ POS   _   _   _  _ _
        \\ commit get_account_transfers
    );
}

test "get_account_transfers: invalid filter" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _ _ _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _ _ _ _ _ _ ok
        \\ commit create_accounts
        \\
        \\ transfer T1 A1 A2    2   _  _  _  _    0 L1 C1   _ PEN   _   _   _   _  _ _ ok
        \\ transfer T2 A1 A2    1  T1  _  _  _    0 L1 C1   _   _ POS   _   _   _  _ _ ok
        \\ commit create_transfers
        \\
        \\ get_account_transfers A3 _  _  10 DR CR _   // Invalid account.
        \\ commit get_account_transfers                // Empty result.
        \\
        \\ get_account_transfers A1 _  _  10 _  _  _   // Invalid filter flags.
        \\ commit get_account_transfers                // Empty result.
        \\
        \\ get_account_transfers A1 T2 T1 10 DR CR _   // Invalid timestamp_min > timestamp_max.
        \\ commit get_account_transfers                // Empty result.
        \\
        \\ get_account_transfers A1 _   _  0 DR CR _   // Invalid limit.
        \\ commit get_account_transfers                // Empty result.
        \\
        \\ get_account_transfers A1 _   _ 10 DR CR _   // Success.
        \\ get_account_transfers_result T1 A1 A2    2   _  _  _  _    0 L1 C1   _ PEN   _   _   _   _  _ _
        \\ get_account_transfers_result T2 A1 A2    1  T1  _  _  _    0 L1 C1   _   _ POS   _   _   _  _ _
        \\ commit get_account_transfers
    );
}

test "get_account_balances: single-phase" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _ _ _ HIST _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _ _ _ HIST _ _ ok
        \\ commit create_accounts
        \\
        \\ transfer T1 A1 A2   10   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ ok
        \\ transfer T2 A2 A1   11   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ ok
        \\ transfer T3 A1 A2   12   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ ok
        \\ transfer T4 A2 A1   13   _  _  _  _    _ L1 C1   _   _   _   _   _   _  _ _ ok
        \\ commit create_transfers
        \\
        \\ get_account_balances A1 _ _ 10 DR CR  _ // Debits + credits, chronological.
        \\ get_account_balances_result T1 0 10 0  0
        \\ get_account_balances_result T2 0 10 0 11
        \\ get_account_balances_result T3 0 22 0 11
        \\ get_account_balances_result T4 0 22 0 24
        \\ commit get_account_balances
        \\
        \\ get_account_balances A1  _  _  2 DR CR  _ // Debits + credits, limit=2.
        \\ get_account_balances_result T1 0 10 0  0
        \\ get_account_balances_result T2 0 10 0 11
        \\ commit get_account_balances
        \\
        \\ get_account_balances A1 T3  _ 10 DR CR  _ // Debits + credits, timestamp_min>0.
        \\ get_account_balances_result T3 0 22 0 11
        \\ get_account_balances_result T4 0 22 0 24
        \\ commit get_account_balances
        \\
        \\ get_account_balances A1  _ T2 10 DR CR  _ // Debits + credits, timestamp_max>0.
        \\ get_account_balances_result T1 0 10 0  0
        \\ get_account_balances_result T2 0 10 0 11
        \\ commit get_account_balances
        \\
        \\ get_account_balances A1 T2 T3 10 DR CR  _ // Debits + credits, 0 < timestamp_min ≤ timestamp_max.
        \\ get_account_balances_result T2 0 10 0 11
        \\ get_account_balances_result T3 0 22 0 11
        \\ commit get_account_balances
        \\
        \\ get_account_balances A1  _  _ 10 DR CR REV // Debits + credits, reverse-chronological.
        \\ get_account_balances_result T4 0 22 0 24
        \\ get_account_balances_result T3 0 22 0 11
        \\ get_account_balances_result T2 0 10 0 11
        \\ get_account_balances_result T1 0 10 0  0
        \\ commit get_account_balances
        \\
        \\ get_account_balances A1  _  _ 10 DR  _  _ // Debits only.
        \\ get_account_balances_result T1 0 10 0  0
        \\ get_account_balances_result T3 0 22 0 11
        \\ commit get_account_balances
        \\
        \\ get_account_balances A1  _  _ 10  _ CR  _ // Credits only.
        \\ get_account_balances_result T2 0 10 0 11
        \\ get_account_balances_result T4 0 22 0 24
        \\ commit get_account_balances
    );
}

test "get_account_balances: two-phase" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _ _ _ HIST _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _ _ _ HIST _ _ ok
        \\ commit create_accounts
        \\
        \\ transfer T1 A1 A2    1   _  _  _  _    0 L1 C1   _ PEN   _   _   _   _  _ _ ok
        \\ transfer T2 A1 A2    _  T1  _  _  _    0 L1 C1   _   _ POS   _   _   _  _ _ ok
        \\ commit create_transfers
        \\
        \\ get_account_balances A1 _ _ 10 DR CR  _
        \\ get_account_balances_result T1 1 0 0 0
        \\ get_account_balances_result T2 0 1 0 0
        \\ commit get_account_balances
    );
}

test "get_account_balances: invalid filter" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _ _ _ HIST _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _ _ _    _ _ _ ok
        \\ commit create_accounts
        \\
        \\ transfer T1 A1 A2    2   _  _  _  _    0 L1 C1   _   _   _   _   _   _  _ _ ok
        \\ transfer T2 A1 A2    1   _  _  _  _    0 L1 C1   _   _   _   _   _   _  _ _ ok
        \\ commit create_transfers
        \\
        \\ get_account_balances A3 _  _  10 DR CR _   // Invalid account.
        \\ commit get_account_balances                // Empty result.
        \\
        \\ get_account_balances A2 _  _  10 DR CR _   // Account without flags.history.
        \\ commit get_account_balances                // Empty result.
        \\
        \\ get_account_balances A1 _  _  10 _  _  _   // Invalid filter flags.
        \\ commit get_account_balances                // Empty result.
        \\
        \\ get_account_balances A1 T2 T1 10 DR CR _   // Invalid timestamp_min > timestamp_max.
        \\ commit get_account_balances                // Empty result.
        \\
        \\ get_account_balances A1 _   _  0 DR CR _   // Invalid limit.
        \\ commit get_account_balances                // Empty result.
        \\
        \\ get_account_balances A1  _  _ 10 DR CR  _  // Success.
        \\ get_account_balances_result T1 0 2 0 0
        \\ get_account_balances_result T2 0 3 0 0
        \\ commit get_account_balances
    );
}

test "query_accounts" {
    try check(
        \\ account A1  0  0  0  0 U1000 U10 U1 _ L1 C1 _   _   _ _ _ _ ok
        \\ account A2  0  0  0  0 U1000 U11 U2 _ L2 C2 _   _   _ _ _ _ ok
        \\ account A3  0  0  0  0 U1000 U10 U3 _ L3 C3 _   _   _ _ _ _ ok
        \\ account A4  0  0  0  0 U1000 U11 U4 _ L4 C4 _   _   _ _ _ _ ok
        \\ account A5  0  0  0  0 U2000 U10 U1 _ L3 C5 _   _   _ _ _ _ ok
        \\ account A6  0  0  0  0 U2000 U11 U2 _ L2 C6 _   _   _ _ _ _ ok
        \\ account A7  0  0  0  0 U2000 U10 U3 _ L1 C7 _   _   _ _ _ _ ok
        \\ account A8  0  0  0  0 U1000 U10 U1 _ L1 C1 _   _   _ _ _ _ ok
        \\ commit create_accounts

        // WHERE user_data_128=1000:
        \\ query_accounts U1000 U0 U0 L0 C0 _ _ L-0 _
        \\ query_accounts_result A1
        \\ query_accounts_result A2
        \\ query_accounts_result A3
        \\ query_accounts_result A4
        \\ query_accounts_result A8
        \\ commit query_accounts

        // WHERE user_data_128=1000 ORDER BY DESC:
        \\ query_accounts U1000 U0 U0 L0 C0 _ _ L-0 REV
        \\ query_accounts_result A8
        \\ query_accounts_result A4
        \\ query_accounts_result A3
        \\ query_accounts_result A2
        \\ query_accounts_result A1
        \\ commit query_accounts

        // WHERE user_data_64=10 AND user_data_32=3
        \\ query_accounts U0 U10 U3 L0 C0 _ _ L-0 _
        \\ query_accounts_result A3
        \\ query_accounts_result A7
        \\ commit query_accounts

        // WHERE user_data_64=10 AND user_data_32=3 ORDER BY DESC:
        \\ query_accounts U0 U10 U3 L0 C0 _ _ L-0 REV
        \\ query_accounts_result A7
        \\ query_accounts_result A3
        \\ commit query_accounts

        // WHERE user_data_64=11 AND user_data_32=2 AND code=2:
        \\ query_accounts U0 U11 U2 L2 C0 _ _ L-0 _
        \\ query_accounts_result A2
        \\ query_accounts_result A6
        \\ commit query_accounts

        // WHERE user_data_64=11 AND user_data_32=2 AND code=2 ORDER BY DESC:
        \\ query_accounts U0 U11 U2 L2 C0 _ _ L-0 REV
        \\ query_accounts_result A6
        \\ query_accounts_result A2
        \\ commit query_accounts

        // WHERE user_data_128=1000 AND user_data_64=10
        // AND user_data_32=1 AND ledger=1 AND code=1:
        \\ query_accounts U1000 U10 U1 L1 C1 _ _ L-0 _
        \\ query_accounts_result A1
        \\ query_accounts_result A8
        \\ commit query_accounts

        // WHERE user_data_128=1000 AND user_data_64=10
        // AND user_data_32=1 AND ledger=1 AND code=1 ORDER BY DESC:
        \\ query_accounts U1000 U10 U1 L1 C1 _ _ L-0 REV
        \\ query_accounts_result A8
        \\ query_accounts_result A1
        \\ commit query_accounts

        // WHERE user_data_128=1000 AND timestamp >= A3.timestamp:
        \\ query_accounts U1000 U0 U0 L0 C0 A3 _ L-0 _
        \\ query_accounts_result A3
        \\ query_accounts_result A4
        \\ query_accounts_result A8
        \\ commit query_accounts

        // WHERE user_data_128=1000 AND timestamp <= A3.timestamp:
        \\ query_accounts U1000 U0 U0 L0 C0 _ A3 L-0 _
        \\ query_accounts_result A1
        \\ query_accounts_result A2
        \\ query_accounts_result A3
        \\ commit query_accounts

        // WHERE user_data_128=1000 AND timestamp BETWEEN A2.timestamp AND A4.timestamp:
        \\ query_accounts U1000 U0 U0 L0 C0 A2 A4 L-0 _
        \\ query_accounts_result A2
        \\ query_accounts_result A3
        \\ query_accounts_result A4
        \\ commit query_accounts

        // SELECT * :
        \\ query_accounts U0 U0 U0 L0 C0 _ _ L-0 _
        \\ query_accounts_result A1
        \\ query_accounts_result A2
        \\ query_accounts_result A3
        \\ query_accounts_result A4
        \\ query_accounts_result A5
        \\ query_accounts_result A6
        \\ query_accounts_result A7
        \\ query_accounts_result A8
        \\ commit query_accounts

        // SELECT * ORDER BY DESC:
        \\ query_accounts U0 U0 U0 L0 C0 _ _ L-0 REV
        \\ query_accounts_result A8
        \\ query_accounts_result A7
        \\ query_accounts_result A6
        \\ query_accounts_result A5
        \\ query_accounts_result A4
        \\ query_accounts_result A3
        \\ query_accounts_result A2
        \\ query_accounts_result A1
        \\ commit query_accounts

        // SELECT * WHERE timestamp >= A2.timestamp LIMIT 3:
        \\ query_accounts U0 U0 U0 L0 C0 A2 _ L3 _
        \\ query_accounts_result A2
        \\ query_accounts_result A3
        \\ query_accounts_result A4
        \\ commit query_accounts

        // SELECT * LIMIT 1:
        \\ query_accounts U0 U0 U0 L0 C0 _ _ L1 _
        \\ query_accounts_result A1
        \\ commit query_accounts

        // SELECT * ORDER BY DESC LIMIT 1:
        \\ query_accounts U0 U0 U0 L0 C0 _ _ L1 REV
        \\ query_accounts_result A8
        \\ commit query_accounts

        // NOT FOUND:

        // SELECT * LIMIT 0:
        \\ query_accounts U0 U0 U0 L0 C0 _ _ L0 _
        \\ commit query_accounts

        // WHERE user_data_128=3000
        \\ query_accounts U3000 U0 U0 L0 C0 _ _ L-0 _
        \\ commit query_accounts

        // WHERE user_data_128=1000 AND code=5
        \\ query_accounts U1000 U0 U0 L0 C5 _ _ L-0 _
        \\ commit query_accounts

        // WHERE user_data_128=1000 AND user_data_64=10
        // AND user_data_32=1 AND ledger=1 AND code=2:
        \\ query_accounts U1000 U10 U1 L1 C2 _ _ L-0 _
        \\ commit query_accounts

        // WHERE user_data_128=1000 AND timestamp BETWEEN A5.timestamp AND A7.timestamp:
        \\ query_accounts U1000 U0 U0 L0 C0 A5 A7 L-0 _
        \\ commit query_accounts
    );
}

test "query_transfers" {
    try check(
        \\ account A1  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ account A2  0  0  0  0  _  _  _ _ L1 C1   _   _   _ _ _ _ ok
        \\ account A3  0  0  0  0  _  _  _ _ L2 C1   _   _   _ _ _ _ ok
        \\ account A4  0  0  0  0  _  _  _ _ L2 C1   _   _   _ _ _ _ ok
        \\ commit create_accounts

        // Creating transfers:
        \\ transfer T1 A1 A2   10  _ U1000 U10 U1 _ L1 C1 _ _ _ _ _ _ _ _ ok
        \\ transfer T2 A3 A4   11  _ U1000 U11 U2 _ L2 C2 _ _ _ _ _ _ _ _ ok
        \\ transfer T3 A2 A1   12  _ U1000 U10 U3 _ L1 C3 _ _ _ _ _ _ _ _ ok
        \\ transfer T4 A4 A3   13  _ U1000 U11 U4 _ L2 C4 _ _ _ _ _ _ _ _ ok
        \\ transfer T5 A2 A1   14  _ U2000 U10 U1 _ L1 C5 _ _ _ _ _ _ _ _ ok
        \\ transfer T6 A4 A3   15  _ U2000 U11 U2 _ L2 C6 _ _ _ _ _ _ _ _ ok
        \\ transfer T7 A1 A2   16  _ U2000 U10 U3 _ L1 C7 _ _ _ _ _ _ _ _ ok
        \\ transfer T8 A2 A1   17  _ U1000 U10 U1 _ L1 C1 _ _ _ _ _ _ _ _ ok
        \\ commit create_transfers

        // WHERE user_data_128=1000:
        \\ query_transfers U1000 U0 U0 L0 C0 _ _ L-0 _
        \\ query_transfers_result T1
        \\ query_transfers_result T2
        \\ query_transfers_result T3
        \\ query_transfers_result T4
        \\ query_transfers_result T8
        \\ commit query_transfers

        // WHERE user_data_128=1000 ORDER BY DESC:
        \\ query_transfers U1000 U0 U0 L0 C0 _ _ L-0 REV
        \\ query_transfers_result T8
        \\ query_transfers_result T4
        \\ query_transfers_result T3
        \\ query_transfers_result T2
        \\ query_transfers_result T1
        \\ commit query_transfers

        // WHERE user_data_64=10 AND user_data_32=3
        \\ query_transfers U0 U10 U3 L0 C0 _ _ L-0 _
        \\ query_transfers_result T3
        \\ query_transfers_result T7
        \\ commit query_transfers

        // WHERE user_data_64=10 AND user_data_32=3 ORDER BY DESC:
        \\ query_transfers U0 U10 U3 L0 C0 _ _ L-0 REV
        \\ query_transfers_result T7
        \\ query_transfers_result T3
        \\ commit query_transfers

        // WHERE user_data_64=11 AND user_data_32=2 AND code=2:
        \\ query_transfers U0 U11 U2 L2 C0 _ _ L-0 _
        \\ query_transfers_result T2
        \\ query_transfers_result T6
        \\ commit query_transfers

        // WHERE user_data_64=11 AND user_data_32=2 AND code=2 ORDER BY DESC:
        \\ query_transfers U0 U11 U2 L2 C0 _ _ L-0 REV
        \\ query_transfers_result T6
        \\ query_transfers_result T2
        \\ commit query_transfers

        // WHERE user_data_128=1000 AND user_data_64=10
        // AND user_data_32=1 AND ledger=1 AND code=1:
        \\ query_transfers U1000 U10 U1 L1 C1 _ _ L-0 _
        \\ query_transfers_result T1
        \\ query_transfers_result T8
        \\ commit query_transfers

        // WHERE user_data_128=1000 AND user_data_64=10
        // AND user_data_32=1 AND ledger=1 AND code=1 ORDER BY DESC:
        \\ query_transfers U1000 U10 U1 L1 C1 _ _ L-0 REV
        \\ query_transfers_result T8
        \\ query_transfers_result T1
        \\ commit query_transfers

        // WHERE user_data_128=1000 AND timestamp >= T3.timestamp:
        \\ query_transfers U1000 U0 U0 L0 C0 A3 _ L-0 _
        \\ query_transfers_result T3
        \\ query_transfers_result T4
        \\ query_transfers_result T8
        \\ commit query_transfers

        // WHERE user_data_128=1000 AND timestamp <= T3.timestamp:
        \\ query_transfers U1000 U0 U0 L0 C0 _ A3 L-0 _
        \\ query_transfers_result T1
        \\ query_transfers_result T2
        \\ query_transfers_result T3
        \\ commit query_transfers

        // WHERE user_data_128=1000 AND timestamp BETWEEN T2.timestamp AND T4.timestamp:
        \\ query_transfers U1000 U0 U0 L0 C0 A2 A4 L-0 _
        \\ query_transfers_result T2
        \\ query_transfers_result T3
        \\ query_transfers_result T4
        \\ commit query_transfers

        // SELECT * :
        \\ query_transfers U0 U0 U0 L0 C0 _ _ L-0 _
        \\ query_transfers_result T1
        \\ query_transfers_result T2
        \\ query_transfers_result T3
        \\ query_transfers_result T4
        \\ query_transfers_result T5
        \\ query_transfers_result T6
        \\ query_transfers_result T7
        \\ query_transfers_result T8
        \\ commit query_transfers

        // SELECT * ORDER BY DESC:
        \\ query_transfers U0 U0 U0 L0 C0 _ _ L-0 REV
        \\ query_transfers_result T8
        \\ query_transfers_result T7
        \\ query_transfers_result T6
        \\ query_transfers_result T5
        \\ query_transfers_result T4
        \\ query_transfers_result T3
        \\ query_transfers_result T2
        \\ query_transfers_result T1
        \\ commit query_transfers

        // SELECT * WHERE timestamp >= A2.timestamp LIMIT 3:
        \\ query_transfers U0 U0 U0 L0 C0 A2 _ L3 _
        \\ query_transfers_result T2
        \\ query_transfers_result T3
        \\ query_transfers_result T4
        \\ commit query_transfers

        // SELECT * LIMIT 1:
        \\ query_transfers U0 U0 U0 L0 C0 _ _ L1 _
        \\ query_transfers_result T1
        \\ commit query_transfers

        // SELECT * ORDER BY DESC LIMIT 1:
        \\ query_transfers U0 U0 U0 L0 C0 _ _ L1 REV
        \\ query_transfers_result T8
        \\ commit query_transfers

        // NOT FOUND:

        // SELECT * LIMIT 0:
        \\ query_transfers U0 U0 U0 L0 C0 _ _ L0 _
        \\ commit query_transfers

        // WHERE user_data_128=3000
        \\ query_transfers U3000 U0 U0 L0 C0 _ _ L-0 _
        \\ commit query_transfers

        // WHERE user_data_128=1000 AND code=5
        \\ query_transfers U1000 U0 U0 L0 C5 _ _ L-0 _
        \\ commit query_transfers

        // WHERE user_data_128=1000 AND user_data_64=10
        // AND user_data_32=1 AND ledger=1 AND code=2:
        \\ query_transfers U1000 U10 U1 L1 C2 _ _ L-0 _
        \\ commit query_transfers

        // WHERE user_data_128=1000 AND timestamp BETWEEN T5.timestamp AND T7.timestamp:
        \\ query_transfers U1000 U0 U0 L0 C0 A5 A7 L-0 _
        \\ commit query_transfers
    );
}

test "StateMachine: input_valid" {
    const allocator = std.testing.allocator;
    const input = try allocator.alignedAlloc(u8, 16, 2 * TestContext.message_body_size_max);
    defer allocator.free(input);

    const Event = struct {
        operation: TestContext.StateMachine.Operation,
        min: usize,
        max: usize,
        size: usize,
    };

    const events = comptime events: {
        var array: []const Event = &.{};
        for (std.enums.values(TestContext.StateMachine.Operation)) |operation| {
            array = switch (operation) {
                .pulse => array ++ [_]Event{.{
                    .operation = operation,
                    .min = 0,
                    .max = 0,
                    .size = 0,
                }},
                .create_accounts => array ++ [_]Event{.{
                    .operation = operation,
                    .min = 0,
                    .max = @divExact(TestContext.message_body_size_max, @sizeOf(Account)),
                    .size = @sizeOf(Account),
                }},
                .create_transfers => array ++ [_]Event{.{
                    .operation = operation,
                    .min = 0,
                    .max = @divExact(TestContext.message_body_size_max, @sizeOf(Transfer)),
                    .size = @sizeOf(Transfer),
                }},
                .lookup_accounts => array ++ [_]Event{.{
                    .operation = operation,
                    .min = 0,
                    .max = @divExact(TestContext.message_body_size_max, @sizeOf(Account)),
                    .size = @sizeOf(u128),
                }},
                .lookup_transfers => array ++ [_]Event{.{
                    .operation = operation,
                    .min = 0,
                    .max = @divExact(TestContext.message_body_size_max, @sizeOf(Transfer)),
                    .size = @sizeOf(u128),
                }},
                .get_account_transfers => array ++ [_]Event{.{
                    .operation = operation,
                    .min = 1,
                    .max = 1,
                    .size = @sizeOf(AccountFilter),
                }},
                .get_account_balances => array ++ [_]Event{.{
                    .operation = operation,
                    .min = 1,
                    .max = 1,
                    .size = @sizeOf(AccountFilter),
                }},
                .query_accounts => array ++ [_]Event{.{
                    .operation = operation,
                    .min = 1,
                    .max = 1,
                    .size = @sizeOf(QueryFilter),
                }},
                .query_transfers => array ++ [_]Event{.{
                    .operation = operation,
                    .min = 1,
                    .max = 1,
                    .size = @sizeOf(QueryFilter),
                }},
            };
        }
        break :events array;
    };

    var context: TestContext = undefined;
    try context.init(std.testing.allocator);
    defer context.deinit(std.testing.allocator);

    for (events) |event| {
        try std.testing.expect(context.state_machine.input_valid(
            event.operation,
            input[0..0],
        ) == (event.min == 0));

        if (event.size == 0) {
            assert(event.min == 0);
            assert(event.max == 0);
            continue;
        }

        try std.testing.expect(context.state_machine.input_valid(
            event.operation,
            input[0 .. 1 * event.size],
        ));
        try std.testing.expect(context.state_machine.input_valid(
            event.operation,
            input[0 .. event.max * event.size],
        ));
        if ((event.max + 1) * event.size < TestContext.message_body_size_max) {
            try std.testing.expect(!context.state_machine.input_valid(
                event.operation,
                input[0 .. (event.max + 1) * event.size],
            ));
        } else {
            // Don't test input larger than the message body limit, since input_valid() would panic
            // on an assert.
        }
        try std.testing.expect(!context.state_machine.input_valid(
            event.operation,
            input[0 .. 3 * (event.size / 2)],
        ));
    }
}

test "StateMachine: Demuxer" {
    const StateMachine = StateMachineType(
        @import("testing/storage.zig").Storage,
        global_constants.state_machine_config,
    );

    var prng = std.rand.DefaultPrng.init(42);
    inline for ([_]StateMachine.Operation{
        .create_accounts,
        .create_transfers,
    }) |operation| {
        try expect(StateMachine.batch_logical_allowed.get(operation));

        const Result = StateMachine.Result(operation);
        var results: [@divExact(global_constants.message_body_size_max, @sizeOf(Result))]Result =
            undefined;

        for (0..100) |_| {
            // Generate Result errors to Events at random.
            var reply_len: u32 = 0;
            for (0..results.len) |i| {
                if (prng.random().boolean()) {
                    results[reply_len] = .{ .index = @intCast(i), .result = .ok };
                    reply_len += 1;
                }
            }

            // Demux events of random strides from the generated results.
            var demuxer = StateMachine.DemuxerType(operation)
                .init(mem.sliceAsBytes(results[0..reply_len]));
            const event_count: u32 = @intCast(@max(
                1,
                prng.random().uintAtMost(usize, results.len),
            ));
            var event_offset: u32 = 0;
            while (event_offset < event_count) {
                const event_size = @max(
                    1,
                    prng.random().uintAtMost(u32, event_count - event_offset),
                );
                const reply: []Result = @alignCast(
                    mem.bytesAsSlice(Result, demuxer.decode(event_offset, event_size)),
                );
                defer event_offset += event_size;

                for (reply) |*result| {
                    try expectEqual(result.result, .ok);
                    try expect(result.index < event_offset + event_size);
                }
            }
        }
    }
}

test "StateMachine: ref all decls" {
    const IO = @import("io.zig").IO;
    const Storage = @import("storage.zig").Storage(IO);

    const StateMachine = StateMachineType(Storage, .{
        .message_body_size_max = global_constants.message_body_size_max,
        .lsm_batch_multiple = 1,
        .vsr_operations_reserved = 128,
    });

    std.testing.refAllDecls(StateMachine);
}
