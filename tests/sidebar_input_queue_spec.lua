-- Tests for the mid-turn input queue implemented in `Sidebar:handle_submit` / `on_stop`.
--
-- `avante.Sidebar` is heavily coupled to real nvim UI containers (nui splits, windows,
-- buffers), so these tests avoid constructing a full `Sidebar:new()` instance. Instead they
-- call the relevant methods directly with a minimal "fake self" table (Lua doesn't require
-- `self` to come from a real instance -- `Sidebar.method(fake_self, ...)` works exactly like
-- `fake_self:method(...)` would if `fake_self` had the right shape), stubbing out only the
-- collaborators each code path actually touches. This exercises the new queueing logic (and
-- the `just_for_display` exclusion it relies on) without needing a live streaming turn, which
-- the test harness has no way to simulate headlessly.

local Config = require("avante.config")
local History = require("avante.history")
local Sidebar = require("avante.sidebar")

describe("Sidebar input queue: busy submit", function()
  before_each(function() Config.prompt_logger = { enabled = false } end)

  it(
    "queues the request, adds a just_for_display+is_queued history message, and does not touch is_generating",
    function()
      local added = {}
      local fake_self = {
        is_generating = true,
        input_queue = {},
        file_selector = { get_selected_filepaths = function() return { "foo.lua" } end },
        code = { selection = nil },
        add_history_messages = function(_, messages)
          for _, m in ipairs(messages) do
            table.insert(added, m)
          end
        end,
      }

      Sidebar.handle_submit(fake_self, "hello while busy")

      assert.are.equal(1, #fake_self.input_queue)
      assert.are.equal(1, #added)

      local entry = fake_self.input_queue[1]
      assert.are.equal("hello while busy", entry.request)
      assert.are.equal(added[1], entry.message)

      local msg = entry.message
      assert.is_true(msg.is_user_submission)
      assert.is_true(msg.just_for_display)
      assert.is_true(msg.is_queued)
      assert.are.same({ "foo.lua" }, msg.selected_filepaths)
      assert.are.equal("hello while busy", msg.message.content)
      assert.is_true(fake_self.is_generating) -- unaffected by queueing
    end
  )

  it("keeps FIFO order across multiple busy submits", function()
    local fake_self = {
      is_generating = true,
      input_queue = {},
      file_selector = { get_selected_filepaths = function() return {} end },
      code = { selection = nil },
      add_history_messages = function() end,
    }

    Sidebar.handle_submit(fake_self, "first")
    Sidebar.handle_submit(fake_self, "second")
    Sidebar.handle_submit(fake_self, "third")

    assert.are.equal(3, #fake_self.input_queue)
    assert.are.equal("first", fake_self.input_queue[1].request)
    assert.are.equal("second", fake_self.input_queue[2].request)
    assert.are.equal("third", fake_self.input_queue[3].request)
  end)

  it("ignores an empty request instead of queuing a no-op message", function()
    local called = false
    local fake_self = {
      is_generating = true,
      input_queue = {},
      add_history_messages = function() called = true end,
    }

    Sidebar.handle_submit(fake_self, "")

    assert.are.equal(0, #fake_self.input_queue)
    assert.is_false(called)
  end)
end)

describe("Sidebar input queue: API history exclusion", function()
  it("excludes just_for_display queued messages from get_history_messages_for_api, keeps sent ones", function()
    local queued_msg = History.Message:new("user", "queued text", {
      is_user_submission = true,
      just_for_display = true,
      is_queued = true,
    })
    local sent_msg = History.Message:new("user", "sent text", { is_user_submission = true })

    local fake_self = {
      chat_history = { messages = { sent_msg, queued_msg } },
    }

    -- opts.all = true sidesteps the tool-invocation-history/provider machinery further down
    -- get_history_messages_for_api, which isn't relevant to what's under test here: whether
    -- just_for_display messages are filtered out at all.
    local api_messages = Sidebar.get_history_messages_for_api(fake_self, { all = true })

    assert.are.equal(1, #api_messages)
    assert.are.equal(sent_msg.uuid, api_messages[1].uuid)
  end)
end)

describe("Sidebar input queue: drain on turn end", function()
  it("is a no-op when the queue is empty", function()
    local fake_self = { input_queue = {} }
    assert.is_false(Sidebar._maybe_drain_input_queue(fake_self))
  end)

  it("pops the first queued item FIFO and resubmits it via handle_submit with queued_message set", function()
    local msg_a =
      History.Message:new("user", "a", { is_user_submission = true, just_for_display = true, is_queued = true })
    local msg_b =
      History.Message:new("user", "b", { is_user_submission = true, just_for_display = true, is_queued = true })

    local submitted
    local fake_self = {
      input_queue = {
        { request = "a", message = msg_a },
        { request = "b", message = msg_b },
      },
      handle_submit = function(_, request, opts) submitted = { request = request, opts = opts } end,
    }

    local drained = Sidebar._maybe_drain_input_queue(fake_self)

    assert.is_true(drained)
    assert.are.equal(1, #fake_self.input_queue)
    assert.are.equal("b", fake_self.input_queue[1].request)
    assert.are.equal("a", submitted.request)
    assert.are.equal(msg_a, submitted.opts.queued_message)
  end)

  it(
    "does not duplicate the history message: handle_submit re-marks queued_message instead of adding a new one",
    function()
      local msg = History.Message:new("user", "queued text", {
        is_user_submission = true,
        just_for_display = true,
        is_queued = true,
      })

      local added = {}
      local fake_self = {
        _history_cache_invalidated = false,
        add_history_messages = function(_, messages)
          for _, m in ipairs(messages) do
            table.insert(added, m)
          end
        end,
        update_content = function() end,
      }

      -- Directly exercises the branch handle_submit takes for a drained request: this mirrors
      -- the `if request and request ~= "" then ... end` block at the tail of handle_submit,
      -- which is guarded behind get_generate_prompts_options/Llm.stream (network/job code that
      -- can't be driven headlessly here -- see the "full handle_submit reuse path" describe
      -- block below for a test that drives it through the real function).
      local opts = { queued_message = msg }
      if opts.queued_message then
        opts.queued_message.just_for_display = nil
        opts.queued_message.is_queued = nil
        fake_self._history_cache_invalidated = true
        fake_self:update_content("")
      end

      assert.are.equal(0, #added)
      assert.is_nil(msg.just_for_display)
      assert.is_nil(msg.is_queued)
    end
  )
end)

describe("Sidebar input queue: cancel semantics", function()
  it("does nothing when the queue is empty", function()
    local fake_self = { input_queue = {} }
    Sidebar._cancel_return_queued_to_input(fake_self)
    assert.are.equal(0, #fake_self.input_queue)
  end)

  it("pops only the first queued item, removes its display message, and leaves the rest queued", function()
    local msg_a =
      History.Message:new("user", "a", { is_user_submission = true, just_for_display = true, is_queued = true })
    local msg_b =
      History.Message:new("user", "b", { is_user_submission = true, just_for_display = true, is_queued = true })

    local removed
    local fake_self = {
      input_queue = {
        { request = "a", message = msg_a },
        { request = "b", message = msg_b },
      },
      containers = {}, -- no valid input container -> Utils.is_valid_container should short-circuit
      _remove_history_message = function(_, message) removed = message end,
    }

    Sidebar._cancel_return_queued_to_input(fake_self)

    assert.are.equal(msg_a, removed)
    assert.are.equal(1, #fake_self.input_queue)
    assert.are.equal("b", fake_self.input_queue[1].request)
  end)

  it("_remove_history_message splices the message out of chat_history.messages by uuid", function()
    local msg_a = History.Message:new("user", "a")
    local msg_b = History.Message:new("user", "b")
    local saved = false
    local fake_self = {
      chat_history = { messages = { msg_a, msg_b } },
      _history_cache_invalidated = false,
      save_history = function() saved = true end,
      update_content = function() end,
    }

    Sidebar._remove_history_message(fake_self, msg_a)

    assert.are.equal(1, #fake_self.chat_history.messages)
    assert.are.equal(msg_b.uuid, fake_self.chat_history.messages[1].uuid)
    assert.is_true(saved)
    assert.is_true(fake_self._history_cache_invalidated)
  end)
end)

describe("Sidebar input queue: full handle_submit reuse path (mocked Llm)", function()
  local original_llm_module
  local original_sidebar_module

  before_each(function()
    Config.prompt_logger = { enabled = false }
    original_llm_module = package.loaded["avante.llm"]
    original_sidebar_module = package.loaded["avante.sidebar"]
  end)

  after_each(function()
    package.loaded["avante.llm"] = original_llm_module
    package.loaded["avante.sidebar"] = original_sidebar_module
  end)

  it("drains without duplicating the history message end-to-end through handle_submit", function()
    -- Swap in a no-op Llm module and force a fresh require of avante.sidebar so its
    -- module-level `local Llm = require("avante.llm")` upvalue binds to the stub instead of
    -- the real streaming/job code, which can't run headlessly in this harness.
    package.loaded["avante.llm"] = {
      stream = function() end,
      cancel_inflight_request = function() end,
      summarize_memory = function() end,
      CANCEL_PATTERN = "AvanteLLMEscapeStub",
    }
    package.loaded["avante.sidebar"] = nil
    local SidebarMocked = require("avante.sidebar")

    local queued_msg = History.Message:new("user", "queued text", {
      is_user_submission = true,
      just_for_display = true,
      is_queued = true,
    })

    local added = {}
    local result_buf = vim.api.nvim_create_buf(false, true)

    local fake_self = {
      is_generating = false,
      input_queue = {},
      file_selector = { get_selected_filepaths = function() return {} end },
      code = { selection = nil, bufnr = 0 },
      chat_history = { messages = { queued_msg } },
      containers = { result = { bufnr = result_buf } },
      acp_client = nil,
      _history_cache_invalidated = false,
      update_content = function() end,
      clear_state = function() end,
      render_state = function() end,
      add_history_messages = function(_, messages)
        for _, m in ipairs(messages) do
          table.insert(added, m)
        end
      end,
      get_generate_prompts_options = function(_, _request, cb) cb({}) end,
    }

    SidebarMocked.handle_submit(fake_self, "queued text", { queued_message = queued_msg })

    assert.are.equal(0, #added) -- no duplicate "user" message added
    assert.is_nil(queued_msg.just_for_display) -- re-marked, no longer excluded from API history
    assert.is_nil(queued_msg.is_queued) -- badge cleared
    assert.is_true(fake_self.is_generating) -- is_generating dead-flag fix: now actually set

    pcall(vim.api.nvim_buf_delete, result_buf, { force = true })
  end)
end)
