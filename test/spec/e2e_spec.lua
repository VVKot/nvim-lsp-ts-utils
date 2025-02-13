local null_ls = require("null-ls")

local ts_utils = require("nvim-lsp-ts-utils")
local import_all = require("nvim-lsp-ts-utils.import-all")

local api = vim.api
local lsp = vim.lsp

local base_path = "test/files/"

local edit_test_file = function(name)
    vim.cmd("e " .. base_path .. name)
end

local get_buf_content = function(line)
    local content = api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, -1, false)
    assert.equals(vim.tbl_isempty(content), false)

    return line and content[line] or content
end

local lsp_wait = function(time)
    vim.wait(time or 400)
end

describe("e2e", function()
    _G._TEST = true
    null_ls.setup()

    require("lspconfig").tsserver.setup({
        on_attach = function(client)
            client.resolved_capabilities.document_formatting = false
            ts_utils.setup_client(client)
        end,
    })

    ts_utils.setup({
        watch_dir = "",
        eslint_enable_code_actions = true,
        eslint_enable_diagnostics = true,
        enable_formatting = true,
        update_imports_on_move = true,
        eslint_config_fallback = "test/files/.eslintrc.js",
        formatter_config_fallback = "test/files/.prettierrc",
    })

    after_each(function()
        vim.cmd("silent bufdo! bdelete!")
    end)

    describe("fix_current", function()
        before_each(function()
            -- file declares an instance of User but does not import it from test-types.ts
            edit_test_file("fix-current.ts")
            lsp_wait(1000)
        end)

        it("should import missing type", function()
            vim.lsp.diagnostic.goto_prev()
            ts_utils.fix_current()
            lsp_wait()

            -- check that import statement has been added
            assert.equals(get_buf_content(1), [[import { User } from "./test-types";]])
        end)
    end)

    describe("import_all", function()
        before_each(function()
            edit_test_file("import-all.ts")
            lsp_wait()
        end)

        it("should import both missing types", function()
            import_all()
            lsp_wait()

            assert.equals(get_buf_content(1), [[import { User, UserNotification } from "./test-types";]])
        end)
    end)

    describe("eslint", function()
        describe("diagnostics", function()
            local move_eslintrc = function()
                vim.cmd("silent !mv test/files/.eslintrc.js test/files/.eslintrc.bak")
            end
            local reset_eslintrc = function()
                if vim.fn.filereadable("test/files/.eslintrc.bak") == 0 then
                    return
                end

                vim.cmd("silent !mv test/files/.eslintrc.bak test/files/.eslintrc.js")
            end

            after_each(function()
                reset_eslintrc()
            end)

            it("should show eslint diagnostics", function()
                edit_test_file("eslint-code-fix.js")
                lsp_wait()

                local diagnostics = lsp.diagnostic.get()

                assert.equals(vim.tbl_count(diagnostics), 1)
                assert.equals(diagnostics[1].code, "eqeqeq")
                assert.equals(diagnostics[1].message, "Expected '===' and instead saw '=='.")
                assert.equals(diagnostics[1].source, "eslint")
            end)

            it("should create diagnostic from eslint error", function()
                move_eslintrc()
                edit_test_file("eslint-code-fix.js")
                lsp_wait()

                local diagnostics = lsp.diagnostic.get()

                assert.equals(vim.tbl_count(diagnostics), 1)
                assert.matches("Cannot read config file", diagnostics[1].message)
            end)
        end)

        describe("code actions", function()
            before_each(function()
                -- file contains ==, which is a violation of eqeqeq
                edit_test_file("eslint-code-fix.js")
                lsp_wait()

                -- jump to line containing error
                vim.cmd("2")
            end)
            it("should apply eslint fix", function()
                ts_utils.fix_current()
                lsp_wait()

                -- check that eslint fix has been applied, replacing == with ===
                assert.equals(get_buf_content(2), [[  if (typeof user.name === "string") {]])
            end)

            it("should add disable rule comment with matching indentation", function()
                -- specify index to choose disable action
                ts_utils.fix_current(2)
                lsp_wait()

                assert.equals(get_buf_content(2), "  // eslint-disable-next-line eqeqeq")
            end)
        end)
    end)

    describe("organize_imports", function()
        before_each(function()
            -- file imports both User and Notification but only uses User
            edit_test_file("organize-imports.ts")
            lsp_wait()
        end)

        it("should remove unused import (sync)", function()
            ts_utils.organize_imports_sync()
            lsp_wait()

            assert.equals(get_buf_content(1), [[import { User } from "./test-types";]])
        end)

        it("should remove unused import (async)", function()
            ts_utils.organize_imports()
            lsp_wait()

            assert.equals(get_buf_content(1), [[import { User } from "./test-types";]])
        end)
    end)

    describe("formatting", function()
        it("should format file via lsp formatting", function()
            edit_test_file("formatting.ts")
            assert.equals(get_buf_content(1), [[import {User} from "./test-types"]])
            lsp_wait()

            lsp.buf.formatting()
            lsp_wait()

            assert.equals(get_buf_content(1), [[import { User } from './test-types';]])
        end)
    end)
end)

null_ls.shutdown()
