defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  require Logger

  alias SymphonyElixir.AgentTools.{GitHub, Linear}
  alias SymphonyElixir.Linear.Usage, as: LinearUsage
  alias SymphonyElixir.QaAndroid.Driver, as: QaAndroidDriver
  alias SymphonyElixir.QaDriver

  @tool_schemas [
    %{
      "name" => "linear_get_current_issue",
      "description" => "Read full fields for the current Linear issue.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear_get_subissues",
      "description" => "Read direct child issues of the current Linear issue.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear_get_parent_issue",
      "description" => "Read the parent issue of the current Linear issue, if any.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear_get_comments",
      "description" => "Read comments on the current Linear issue, newest first. A reply carries its thread's first comment id in `parent.id`.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
        }
      }
    },
    %{
      "name" => "linear_get_related_issues",
      "description" => "Read blocks and blocked-by issue summaries for the current Linear issue.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear_update_state",
      "description" =>
        "Move the current Linear issue to a state in its team's workflow. Moving it to Merging is refused: only a human can approve a merge. With Auto Review on, moving it to In Review is refused too: Symphony moves the issue once the PR is open.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["state_name_or_id"],
        "properties" => %{
          "state_name_or_id" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "linear_add_comment",
      "description" => "Add a comment to the current Linear issue. Pass `parent_id` to reply under one of its comments.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["body"],
        "properties" => %{
          "body" => %{"type" => "string"},
          "parent_id" => %{
            "type" => "string",
            "description" => "Id of a comment on the current issue to reply under (for a reply, its thread's first comment)."
          }
        }
      }
    },
    %{
      "name" => "linear_update_comment",
      "description" => "Update a comment created earlier by this run.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["comment_id", "body"],
        "properties" => %{
          "comment_id" => %{"type" => "string"},
          "body" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "linear_delete_comment",
      "description" => "Delete a comment created earlier by this run.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["comment_id"],
        "properties" => %{
          "comment_id" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "linear_attach_url",
      "description" => "Attach a URL to the current Linear issue.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["url"],
        "properties" => %{
          "url" => %{"type" => "string"},
          "title" => %{"type" => ["string", "null"], "maxLength" => 120}
        }
      }
    },
    %{
      "name" => "linear_attach_file",
      "description" =>
        "Upload and attach a workspace-local file to the current Linear issue. Uploads are private by default; make_public true creates a world-readable Linear CDN URL and is restricted to configured image/PDF extensions by default.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["local_path"],
        "properties" => %{
          "local_path" => %{"type" => "string"},
          "title" => %{"type" => ["string", "null"], "maxLength" => 120},
          "make_public" => %{
            "type" => "boolean",
            "default" => false,
            "description" =>
              "Set true only when the artifact is intentionally shareable; public uploads create world-readable Linear CDN URLs and are restricted to configured image/PDF extensions by default."
          }
        }
      }
    },
    %{
      "name" => "linear_create_subissue",
      "description" =>
        "Create a child issue of the current Linear issue, in its team and project and assigned to its assignee. The new issue lands in Backlog; a human promotes it. Pass `blocked_by` with the identifiers of earlier sibling sub-issues it depends on to add Linear blocked-by links. Capped per run.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["title", "description"],
        "properties" => %{
          "title" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "priority" => %{
            "type" => "integer",
            "minimum" => 0,
            "maximum" => 4,
            "description" => "Linear priority: 0 none, 1 urgent, 2 high, 3 medium, 4 low."
          },
          "blocked_by" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Identifiers (e.g. TP-12) of sub-issues that block this one. Only the current issue's existing sub-issues and ones created earlier in this run are accepted."
          }
        }
      }
    },
    %{
      "name" => "linear_update_subissue",
      "description" =>
        "Change a Backlog sub-issue of the current Linear issue to bring a plan in line with review comments: replace its `title` and/or `description`, set `blocked_by` to the complete list of sibling sub-issues that block it, or cancel it with `cancel_reason` (posted on it first). A sub-issue outside Backlog was promoted by a person and is refused.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["identifier"],
        "properties" => %{
          "identifier" => %{"type" => "string", "description" => "Identifier (e.g. TP-12) of a sub-issue of the current issue."},
          "title" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "blocked_by" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Every sibling sub-issue that blocks this one. Links to siblings not listed are removed; links to other issues stay."
          },
          "cancel_reason" => %{
            "type" => "string",
            "description" => "Cancel the sub-issue, posting this on it as the reason. Cannot be combined with other changes."
          }
        }
      }
    },
    %{
      "name" => "linear_add_blocked_by",
      "description" =>
        "Mark the current Linear issue blocked by existing issues, such as the gap tickets a final verification filed. Symphony holds an issue in Todo until every blocker is Done or Canceled, then dispatches it again on its own.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["blocked_by"],
        "properties" => %{
          "blocked_by" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "minItems" => 1,
            "description" => "Identifiers (e.g. TP-12) of the issues that block the current one."
          }
        }
      }
    },
    %{
      "name" => "linear_create_project_update",
      "description" => "Post a project update to the current Linear issue's project. Use it once a parent ticket closes out, to summarize the work done. One per run.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["body"],
        "properties" => %{
          "body" => %{"type" => "string", "description" => "Markdown summary of the work."},
          "health" => %{"type" => "string", "enum" => ["onTrack", "atRisk", "offTrack"]}
        }
      }
    },
    %{
      "name" => "linear_request_human_action",
      "description" =>
        "Record that the current issue needs something only a human can do: a missing secret or permission, a product decision, an account setup, a manual check on a device. Symphony lists it, with your steps, in a Linear project update for the human, and drops it once the issue moves on. Never put a secret value in any field. A request with the same title that is still open is not posted again. Then follow the blocked-access escape hatch as usual.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["title", "why", "steps"],
        "properties" => %{
          "title" => %{"type" => "string", "maxLength" => 120, "description" => "What the human must do, as an instruction: `Add the release signing secrets`."},
          "why" => %{"type" => "string", "description" => "Why it is needed and what fails without it, in one or two sentences."},
          "steps" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "minItems" => 1,
            "maxItems" => 15,
            "description" => "Exact steps, one instruction each, detailed enough to do from a phone without opening anything else. Name settings and secret names, never values."
          },
          "unblocks" => %{"type" => "string", "description" => "What becomes possible once it is done, e.g. `the Release workflow on main`."},
          "est_minutes" => %{"type" => "integer", "minimum" => 1, "maximum" => 480, "description" => "Rough minutes the human needs."}
        }
      }
    },
    %{
      "name" => "github_get_pull_request",
      "description" => "Read the pull request for the current workspace branch in the configured origin repo.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "github_fetch_origin",
      "description" => "Fetch the configured origin remote for the current workspace.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "github_create_pull_request",
      "description" => "Create a pull request from the current workspace branch to the configured origin repo default branch.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["title", "body"],
        "properties" => %{
          "title" => %{"type" => "string"},
          "body" => %{"type" => "string"},
          "draft" => %{"type" => "boolean"}
        }
      }
    },
    %{
      "name" => "github_update_pull_request_body",
      "description" => "Update the body of the pull request for the current workspace branch.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["body"],
        "properties" => %{
          "body" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "github_add_pr_comment",
      "description" => "Add a comment to the pull request for the current workspace branch.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["body"],
        "properties" => %{
          "body" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "github_reply_to_review_comment",
      "description" => "Reply under an existing inline review comment thread on the pull request for the current workspace branch.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["comment_id", "body"],
        "properties" => %{
          "comment_id" => %{"type" => ["integer", "string"]},
          "body" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "github_push_branch",
      "description" => "Push the current workspace branch to origin.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "github_merge_pull_request",
      "description" => "Squash-merge the pull request for the current workspace branch. Only allowed while the current Linear issue is in Merging and no checks are failing or pending.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "github_get_pr_checks",
      "description" => "Read status checks for the pull request for the current workspace branch.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "github_list_pr_comments",
      "description" => "Read top-level comments for the pull request for the current workspace branch.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "github_list_pr_review_comments",
      "description" => "Read inline review comments for the pull request for the current workspace branch.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "github_list_pr_reviews",
      "description" => "Read review summaries for the pull request for the current workspace branch.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "github_get_failed_run_log",
      "description" => "Read the length-clamped failed-step log excerpt for the latest failing GitHub Actions run on the current pull request.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    }
  ]

  # Host-side macOS app tools (`SymphonyElixir.QaDriver`), listed and allowed only in
  # the `:qa` scope.
  @pid_property %{"type" => "integer", "minimum" => 1, "description" => "A PID qa_launch_app returned."}
  @element_path_property %{"type" => "string", "description" => "An element path from qa_ax_tree, like `0.2.1`."}

  @qa_tool_schemas [
    %{
      "name" => "qa_build",
      "description" => "Run the configured macos_app build command in the QA worktree on the host. Takes no arguments; fails when the worktree has edits outside qa-evidence/.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "qa_launch_app",
      "description" => "Launch the configured app bundle the last qa_build produced, in QA mode (private settings and secrets). Returns its PID.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "qa_quit_app",
      "description" => "Quit an app qa_launch_app launched and return its recent output.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["pid"],
        "properties" => %{"pid" => @pid_property}
      }
    },
    %{
      "name" => "qa_screenshot",
      "description" => "Capture the launched app's on-screen windows (or one window_id) to qa-evidence/<name>.png. Returns the files with each window's frame.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["pid", "name"],
        "properties" => %{
          "pid" => @pid_property,
          "name" => %{"type" => "string", "description" => "File name without extension: letters, digits, `.`, `_`, `-`."},
          "window_id" => %{"type" => "integer", "minimum" => 1}
        }
      }
    },
    %{
      "name" => "qa_ax_tree",
      "description" =>
        "Read the launched app's accessibility tree: role, title, value, identifier and frame (x, y, w, h) per element. With role or text, returns matching elements as a flat list. Size-capped.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["pid"],
        "properties" => %{
          "pid" => @pid_property,
          "role" => %{"type" => "string", "maxLength" => 64, "description" => "Only elements with this AX role, e.g. AXTextField."},
          "text" => %{"type" => "string", "maxLength" => 200, "description" => "Only elements whose title, value, description or identifier contains this."},
          "max_depth" => %{"type" => "integer", "minimum" => 1, "maximum" => 40, "default" => 12},
          "max_nodes" => %{"type" => "integer", "minimum" => 1, "maximum" => 1000, "default" => 300}
        }
      }
    },
    %{
      "name" => "qa_ax_press",
      "description" => "Perform an accessibility action (AXPress by default, or AXRaise to focus a window) on an element of the launched app.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["pid", "path"],
        "properties" => %{
          "pid" => @pid_property,
          "path" => @element_path_property,
          "action" => %{
            "type" => "string",
            "enum" => ~w(AXPress AXRaise AXShowMenu AXConfirm AXCancel AXIncrement AXDecrement AXPick)
          }
        }
      }
    },
    %{
      "name" => "qa_ax_set_value",
      "description" => "Set the value of a text field or other editable element of the launched app.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["pid", "path", "value"],
        "properties" => %{
          "pid" => @pid_property,
          "path" => @element_path_property,
          "value" => %{"type" => "string", "maxLength" => 10_000}
        }
      }
    }
  ]

  # Host-side Android app tools (`SymphonyElixir.QaAndroid.Driver`), listed and
  # allowed only in the `:qa` scope.
  @application_id_property %{"type" => "string", "description" => "One of the android_app playbook's application_ids."}

  @qa_android_tool_schemas [
    %{
      "name" => "qa_android_install",
      "description" =>
        "Install the APK at the android_app playbook's apk_path, which you build in your sandbox with the playbook's build command, on Symphony's emulator, with fresh app data. Takes no arguments; fails when tracked files in the worktree changed.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "qa_android_launch",
      "description" => "Launch an installed app's launcher activity on the emulator and wait until it is in the foreground. Reports recent logcat when the app exits.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["application_id"],
        "properties" => %{"application_id" => @application_id_property}
      }
    },
    %{
      "name" => "qa_android_stop",
      "description" => "Force-stop an app on the emulator.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["application_id"],
        "properties" => %{"application_id" => @application_id_property}
      }
    },
    %{
      "name" => "qa_android_screenshot",
      "description" => "Capture the emulator's screen to qa-evidence/<name>.png. Each name can be used once.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["name"],
        "properties" => %{
          "name" => %{"type" => "string", "description" => "File name without extension: letters, digits, `.`, `_`, `-`."}
        }
      }
    },
    %{
      "name" => "qa_android_ui_tree",
      "description" =>
        "Read what is on the emulator's screen (uiautomator dump) as a flat list of nodes: path (like `0.2.1`), class, text, content-desc, resource-id, bounds and the clickable, focused, enabled, checked and scrollable flags, plus the foreground package. Filters keep only matching nodes. Size-capped; says when nodes were left out.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "text" => %{"type" => "string", "maxLength" => 200, "description" => "Only nodes whose text or content-desc contains this, ignoring case."},
          "resource_id" => %{"type" => "string", "maxLength" => 200, "description" => "Only nodes with this resource-id, full (`com.example.app:id/login`) or after the `/` (`login`)."},
          "class" => %{"type" => "string", "maxLength" => 200, "description" => "Only nodes of this class, full (`android.widget.Button`) or simple (`Button`)."},
          "max_depth" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 30},
          "max_nodes" => %{"type" => "integer", "minimum" => 1, "maximum" => 1000, "default" => 300}
        }
      }
    },
    %{
      "name" => "qa_android_tap",
      "description" => "Tap the centre of a node from the last qa_android_ui_tree result, or a point on the display.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "path" => %{"type" => "string", "description" => "A node path from the last qa_android_ui_tree result, like `0.2.1`."},
          "x" => %{"type" => "integer", "minimum" => 0, "description" => "With y, instead of path: a point in display pixels."},
          "y" => %{"type" => "integer", "minimum" => 0}
        }
      }
    },
    %{
      "name" => "qa_android_type",
      "description" => "Type text into the focused field on the emulator. Printable ASCII only; a newline presses Enter.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["text"],
        "properties" => %{"text" => %{"type" => "string", "minLength" => 1, "maxLength" => 500}}
      }
    },
    %{
      "name" => "qa_android_key",
      "description" => "Press a key on the emulator. ime_action is the Enter a single-line field treats as its keyboard action.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["key"],
        "properties" => %{
          "key" => %{"type" => "string", "enum" => ~w(back enter ime_action tab del dpad_up dpad_down dpad_left dpad_right escape)}
        }
      }
    },
    %{
      "name" => "qa_android_rotate",
      "description" => "Turn off auto-rotate and rotate the emulator. Reset to portrait when the QA pass ends.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["orientation"],
        "properties" => %{"orientation" => %{"type" => "string", "enum" => ["portrait", "landscape"]}}
      }
    },
    %{
      "name" => "qa_android_dark_mode",
      "description" => "Turn the emulator's dark theme on or off. Turned off when the QA pass ends.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["mode"],
        "properties" => %{"mode" => %{"type" => "string", "enum" => ["on", "off"]}}
      }
    },
    %{
      "name" => "qa_android_font_scale",
      "description" => "Set the emulator's font size scale. Reset to 1.0 when the QA pass ends.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["scale"],
        "properties" => %{"scale" => %{"type" => "number", "enum" => [0.85, 1.0, 1.15, 1.3, 1.5, 1.8, 2.0]}}
      }
    }
  ]

  @tool_names Enum.map(@tool_schemas, & &1["name"])
  @invalid_tool_names Enum.reject(@tool_names, fn name -> Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name) end)

  if @invalid_tool_names != [] do
    raise ArgumentError, "dynamic tool names must match ^[a-zA-Z0-9_-]+$: #{inspect(@invalid_tool_names)}"
  end

  @allowed_arguments %{
    "linear_get_current_issue" => [],
    "linear_get_subissues" => [],
    "linear_get_parent_issue" => [],
    "linear_get_comments" => ["limit"],
    "linear_get_related_issues" => [],
    "linear_update_state" => ["state_name_or_id"],
    "linear_add_comment" => ["body", "parent_id"],
    "linear_update_comment" => ["comment_id", "body"],
    "linear_delete_comment" => ["comment_id"],
    "linear_attach_url" => ["url", "title"],
    "linear_attach_file" => ["local_path", "title", "make_public"],
    "linear_create_subissue" => ["title", "description", "priority", "blocked_by"],
    "linear_update_subissue" => ["identifier", "title", "description", "blocked_by", "cancel_reason"],
    "linear_add_blocked_by" => ["blocked_by"],
    "linear_create_project_update" => ["body", "health"],
    "linear_request_human_action" => ["title", "why", "steps", "unblocks", "est_minutes"],
    "github_get_pull_request" => [],
    "github_fetch_origin" => [],
    "github_create_pull_request" => ["title", "body", "draft"],
    "github_update_pull_request_body" => ["body"],
    "github_add_pr_comment" => ["body"],
    "github_reply_to_review_comment" => ["comment_id", "body"],
    "github_push_branch" => [],
    "github_merge_pull_request" => [],
    "github_get_pr_checks" => [],
    "github_list_pr_comments" => [],
    "github_list_pr_review_comments" => [],
    "github_list_pr_reviews" => [],
    "github_get_failed_run_log" => [],
    "qa_build" => [],
    "qa_launch_app" => [],
    "qa_quit_app" => ["pid"],
    "qa_screenshot" => ["pid", "name", "window_id"],
    "qa_ax_tree" => ["pid", "role", "text", "max_depth", "max_nodes"],
    "qa_ax_press" => ["pid", "path", "action"],
    "qa_ax_set_value" => ["pid", "path", "value"],
    "qa_android_install" => [],
    "qa_android_launch" => ["application_id"],
    "qa_android_stop" => ["application_id"],
    "qa_android_screenshot" => ["name"],
    "qa_android_ui_tree" => ["text", "resource_id", "class", "max_depth", "max_nodes"],
    "qa_android_tap" => ["path", "x", "y"],
    "qa_android_type" => ["text"],
    "qa_android_key" => ["key"],
    "qa_android_rotate" => ["orientation"],
    "qa_android_dark_mode" => ["mode"],
    "qa_android_font_scale" => ["scale"]
  }
  @legacy_tool_aliases %{
    "linear.get_current_issue" => "linear_get_current_issue",
    "linear.get_subissues" => "linear_get_subissues",
    "linear.get_parent_issue" => "linear_get_parent_issue",
    "linear.get_comments" => "linear_get_comments",
    "linear.get_related_issues" => "linear_get_related_issues",
    "linear.update_state" => "linear_update_state",
    "linear.add_comment" => "linear_add_comment",
    "linear.update_comment" => "linear_update_comment",
    "linear.delete_comment" => "linear_delete_comment",
    "linear.attach_url" => "linear_attach_url",
    "linear.attach_file" => "linear_attach_file",
    "linear.create_subissue" => "linear_create_subissue",
    "linear.add_blocked_by" => "linear_add_blocked_by",
    "linear.create_project_update" => "linear_create_project_update",
    "github.get_pull_request" => "github_get_pull_request",
    "github.fetch_origin" => "github_fetch_origin",
    "github.create_pull_request" => "github_create_pull_request",
    "github.update_pull_request_body" => "github_update_pull_request_body",
    "github.add_pr_comment" => "github_add_pr_comment",
    "github.reply_to_review_comment" => "github_reply_to_review_comment",
    "github.push_branch" => "github_push_branch",
    "github.get_pr_checks" => "github_get_pr_checks",
    "github.list_pr_comments" => "github_list_pr_comments",
    "github.list_pr_review_comments" => "github_list_pr_review_comments",
    "github.list_pr_reviews" => "github_list_pr_reviews",
    "github.get_failed_run_log" => "github_get_failed_run_log"
  }
  @read_only_tools MapSet.new([
                     "linear_get_current_issue",
                     "linear_get_subissues",
                     "linear_get_parent_issue",
                     "linear_get_comments",
                     "linear_get_related_issues",
                     "github_get_pull_request",
                     "github_get_pr_checks",
                     "github_list_pr_comments",
                     "github_list_pr_review_comments",
                     "github_list_pr_reviews",
                     "github_get_failed_run_log"
                   ])

  # The QA agent reads like the reviewer and may attach evidence files; it never
  # moves the issue, comments, or writes to GitHub.
  @qa_tools MapSet.put(@read_only_tools, "linear_attach_file")

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    context = tool_context(opts)
    tool = normalize_tool_name(tool)

    case Map.fetch(@allowed_arguments, tool) do
      {:ok, allowed_arguments} ->
        with_issue_caller(context.issue, fn ->
          with_arguments(tool, arguments, allowed_arguments, &execute_authorized_tool(tool, context, &1, opts))
        end)

      :error ->
        tool_not_found_response(tool)
    end
  end

  # Linear requests from an agent's tool calls count against its issue.
  defp with_issue_caller(%{identifier: identifier}, fun) when is_binary(identifier), do: LinearUsage.with_caller({:agent, identifier}, fun)
  defp with_issue_caller(_issue, fun), do: fun.()

  @spec tool_specs() :: [map()]
  def tool_specs, do: @tool_schemas

  @spec tool_specs(:default | :read_only | :qa | nil) :: [map()]
  def tool_specs(:read_only), do: Enum.filter(@tool_schemas, &(Map.get(&1, "name") in @read_only_tools))
  def tool_specs(:qa), do: Enum.filter(@tool_schemas, &(Map.get(&1, "name") in @qa_tools)) ++ @qa_tool_schemas ++ @qa_android_tool_schemas
  def tool_specs(_scope), do: tool_specs()

  defp tool_context(opts) do
    %{
      issue: Keyword.get(opts, :issue),
      issue_id: Keyword.get(opts, :issue_id),
      workspace: Keyword.get(opts, :workspace),
      comment_registry: Keyword.get(opts, :comment_registry),
      command_security: Keyword.get(opts, :command_security) || %{}
    }
  end

  defp with_arguments(tool, arguments, allowed_keys, fun) when is_function(fun, 1) do
    with {:ok, args} <- normalize_arguments(arguments),
         :ok <- reject_scope_arguments(tool, args),
         :ok <- validate_argument_keys(args, allowed_keys),
         {:ok, result} <- fun.(args) do
      success_response(result)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_tool("linear_" <> _rest = tool, context, args, opts), do: execute_linear_tool(tool, context, args, opts)
  defp execute_tool("github_" <> _rest = tool, context, args, opts), do: execute_github_tool(tool, context, args, opts)

  defp execute_tool("qa_android_" <> _rest = tool, _context, args, opts),
    do: QaAndroidDriver.call_tool(Keyword.get(opts, :qa_android_driver), tool, args)

  defp execute_tool("qa_" <> _rest = tool, _context, args, opts), do: QaDriver.call_tool(Keyword.get(opts, :qa_driver), tool, args)

  defp execute_authorized_tool(tool, context, args, opts) do
    case authorize_tool_scope(tool, opts) do
      :ok -> execute_tool(tool, context, args, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_tool_scope("qa_" <> _rest = tool, opts) do
    case Keyword.get(opts, :tool_scope) do
      :qa -> :ok
      scope -> {:error, {:tool_scope_rejected, scope, tool}}
    end
  end

  defp authorize_tool_scope(tool, opts) do
    case Keyword.get(opts, :tool_scope) do
      :read_only ->
        if MapSet.member?(@read_only_tools, tool), do: :ok, else: {:error, {:tool_scope_rejected, :read_only, tool}}

      :qa ->
        if MapSet.member?(@qa_tools, tool), do: :ok, else: {:error, {:tool_scope_rejected, :qa, tool}}

      _scope ->
        :ok
    end
  end

  defp execute_linear_tool("linear_get_current_issue", context, _args, opts), do: Linear.get_current_issue(context, opts)
  defp execute_linear_tool("linear_get_subissues", context, _args, opts), do: Linear.get_subissues(context, opts)
  defp execute_linear_tool("linear_get_parent_issue", context, _args, opts), do: Linear.get_parent_issue(context, opts)
  defp execute_linear_tool("linear_get_related_issues", context, _args, opts), do: Linear.get_related_issues(context, opts)

  defp execute_linear_tool("linear_get_comments", context, args, opts) do
    Linear.get_comments(context, Map.get(args, "limit"), opts)
  end

  defp execute_linear_tool("linear_update_state", context, args, opts) do
    Linear.update_state(context, Map.get(args, "state_name_or_id"), opts)
  end

  defp execute_linear_tool("linear_add_comment", context, args, opts) do
    opts = if Map.has_key?(args, "parent_id"), do: Keyword.put(opts, :parent_id, args["parent_id"]), else: opts

    with {:ok, response} <- Linear.add_comment(context, Map.get(args, "body"), opts) do
      {:ok, compact_comment_mutation_response(response, "commentCreate", opts)}
    end
  end

  defp execute_linear_tool("linear_update_comment", context, args, opts) do
    with {:ok, response} <- Linear.update_comment(context, Map.get(args, "comment_id"), Map.get(args, "body"), opts) do
      {:ok, compact_comment_mutation_response(response, "commentUpdate", opts)}
    end
  end

  defp execute_linear_tool("linear_delete_comment", context, args, opts) do
    Linear.delete_comment(context, Map.get(args, "comment_id"), opts)
  end

  defp execute_linear_tool("linear_attach_url", context, args, opts) do
    Linear.attach_url(context, Map.get(args, "url"), Map.get(args, "title"), opts)
  end

  defp execute_linear_tool("linear_attach_file", context, args, opts) do
    opts = Keyword.put(opts, :make_public, Map.get(args, "make_public", false) == true)
    Linear.attach_file(context, Map.get(args, "local_path"), Map.get(args, "title"), opts)
  end

  defp execute_linear_tool("linear_create_subissue", context, args, opts) do
    Linear.create_subissue(context, args, opts)
  end

  defp execute_linear_tool("linear_update_subissue", context, args, opts) do
    Linear.update_subissue(context, args, opts)
  end

  defp execute_linear_tool("linear_add_blocked_by", context, args, opts) do
    Linear.add_blocked_by(context, args, opts)
  end

  defp execute_linear_tool("linear_create_project_update", context, args, opts) do
    Linear.create_project_update(context, args, opts)
  end

  defp execute_linear_tool("linear_request_human_action", context, args, opts) do
    Linear.request_human_action(context, args, opts)
  end

  defp execute_github_tool("github_get_pull_request", context, _args, opts), do: GitHub.get_pull_request(context, opts)
  defp execute_github_tool("github_fetch_origin", context, _args, opts), do: GitHub.fetch_origin(context, opts)

  defp execute_github_tool("github_create_pull_request", context, args, opts) do
    GitHub.create_pull_request(context, Map.get(args, "title"), Map.get(args, "body"), Map.get(args, "draft"), opts)
  end

  defp execute_github_tool("github_update_pull_request_body", context, args, opts) do
    GitHub.update_pull_request_body(context, Map.get(args, "body"), opts)
  end

  defp execute_github_tool("github_add_pr_comment", context, args, opts) do
    GitHub.add_pr_comment(context, Map.get(args, "body"), opts)
  end

  defp execute_github_tool("github_reply_to_review_comment", context, args, opts) do
    GitHub.reply_to_review_comment(context, Map.get(args, "comment_id"), Map.get(args, "body"), opts)
  end

  defp execute_github_tool("github_push_branch", context, _args, opts), do: GitHub.push_branch(context, opts)
  defp execute_github_tool("github_merge_pull_request", context, _args, opts), do: GitHub.merge_pull_request(context, opts)
  defp execute_github_tool("github_get_pr_checks", context, _args, opts), do: GitHub.get_pr_checks(context, opts)
  defp execute_github_tool("github_list_pr_comments", context, _args, opts), do: GitHub.list_pr_comments(context, opts)

  defp execute_github_tool("github_list_pr_review_comments", context, _args, opts) do
    GitHub.list_pr_review_comments(context, opts)
  end

  defp execute_github_tool("github_list_pr_reviews", context, _args, opts), do: GitHub.list_pr_reviews(context, opts)
  defp execute_github_tool("github_get_failed_run_log", context, _args, opts), do: GitHub.get_failed_run_log(context, opts)

  defp normalize_tool_name(tool) when is_binary(tool), do: Map.get(@legacy_tool_aliases, tool, tool)
  defp normalize_tool_name(tool), do: tool

  defp normalize_arguments(nil), do: {:ok, %{}}
  defp normalize_arguments(arguments) when is_map(arguments), do: {:ok, stringify_keys(arguments)}
  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp stringify_keys(arguments) do
    Map.new(arguments, fn {key, value} -> {to_string(key), value} end)
  end

  # A sub-issue's team, project, parent, assignee and state all come from the current issue.
  defp reject_scope_arguments("linear_create_subissue" = tool, args) do
    scope_keys = [
      "team",
      "teamId",
      "team_id",
      "project",
      "projectId",
      "project_id",
      "parent",
      "parentId",
      "parent_id",
      "assignee",
      "assigneeId",
      "assignee_id",
      "state",
      "stateId",
      "state_id"
    ]

    with :ok <- reject_scope_arguments("linear_", args) do
      if Enum.any?(Map.keys(args), &(&1 in scope_keys)) do
        {:error, {:scope_argument_rejected, tool}}
      else
        :ok
      end
    end
  end

  defp reject_scope_arguments("linear_" <> _rest, args) do
    if Enum.any?(Map.keys(args), &(&1 in ["issue_id", "issueId", "id"])) do
      {:error, :scope_argument_rejected}
    else
      :ok
    end
  end

  defp reject_scope_arguments("github_" <> _rest, args) do
    scope_keys = [
      "repo",
      "repository",
      "remote",
      "head",
      "base",
      "branch",
      "current_branch",
      "currentBranch",
      "ref",
      "refspec"
    ]

    if Enum.any?(Map.keys(args), &(&1 in scope_keys)) do
      {:error, {:scope_argument_rejected, :github}}
    else
      :ok
    end
  end

  defp reject_scope_arguments(_tool, _args), do: :ok

  defp validate_argument_keys(args, allowed_keys) do
    allowed = MapSet.new(allowed_keys)

    args
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> case do
      [] -> :ok
      keys -> {:error, {:unexpected_arguments, keys}}
    end
  end

  defp success_response(payload) do
    # Read tools must wrap any untrusted external text before returning it here;
    # this boundary stays schema-neutral and only encodes the prepared payload.
    dynamic_tool_response(true, encode_payload(payload))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp tool_not_found_response(tool) do
    failure_response(%{
      "error" => %{
        "code" => "tool_not_found",
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => @tool_names
      }
    })
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  # Strip the echoed comment body from Linear mutation responses before returning to Codex. The
  # body the agent just sent us would otherwise round-trip through the app-server stdout stream as
  # part of the tool result, which can exceed Codex's stdio write limits on long comments and
  # wedge the turn. Keep id/url plus bodyLength so the model can still confirm the write
  # succeeded. If the response shape drifts (Linear API change, partial-failure envelope, etc.)
  # we surface that with a warning so the silent regression is observable rather than just
  # leaking the full body back into the stream.
  defp compact_comment_mutation_response(response, field, opts) when is_map(response) and is_binary(field) do
    case get_in(response, ["data", field, "comment"]) do
      %{} = comment ->
        put_in(response, ["data", field, "comment"], compact_comment_payload(comment))

      _comment ->
        # `data` can be `nil` (Linear sometimes returns `{:ok, %{"data" => nil}}` because
        # check_mutation_success treats a missing `success` key as success). `Map.get/3`'s default
        # is only used when the key is absent, so we must guard against the nil value separately
        # before calling `Map.keys/1`.
        data_keys =
          case Map.get(response, "data") do
            data when is_map(data) -> Map.keys(data)
            _ -> []
          end

        Logger.warning(
          "Linear #{field} response missing expected comment shape; comment-body compaction skipped " <>
            "issue_identifier=#{inspect(issue_identifier(opts))} data_keys=#{inspect(data_keys)}"
        )

        response
    end
  end

  defp issue_identifier(opts) do
    case Keyword.get(opts, :issue) do
      %{identifier: identifier} when is_binary(identifier) -> identifier
      _ -> nil
    end
  end

  defp compact_comment_payload(comment) when is_map(comment) do
    comment
    |> Map.take(["id", "url"])
    |> maybe_put_body_length(comment)
  end

  defp maybe_put_body_length(compact, %{"body" => body}) when is_binary(body),
    do: Map.put(compact, "bodyLength", String.length(body))

  defp maybe_put_body_length(compact, _comment), do: compact

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "code" => "invalid_arguments",
        "message" => "Dynamic tools expect an object argument payload."
      }
    }
  end

  defp tool_error_payload(:scope_argument_rejected) do
    %{
      "error" => %{
        "code" => "scope_argument_rejected",
        "message" => "Dynamic Linear tools are scoped to the current issue; issue id arguments are not accepted."
      }
    }
  end

  defp tool_error_payload({:scope_argument_rejected, :github}) do
    %{
      "error" => %{
        "code" => "scope_argument_rejected",
        "message" => "Dynamic GitHub tools are scoped to the current workspace branch and configured origin; repo, remote, head, branch, and refspec arguments are not accepted."
      }
    }
  end

  defp tool_error_payload({:scope_argument_rejected, "linear_create_subissue"}) do
    %{
      "error" => %{
        "code" => "scope_argument_rejected",
        "message" =>
          "linear_create_subissue always creates a Backlog child of the current issue in its team and project, assigned to its assignee; team, project, parent, assignee, and state arguments are not accepted."
      }
    }
  end

  defp tool_error_payload({:unexpected_arguments, keys}) do
    %{
      "error" => %{
        "code" => "unexpected_arguments",
        "message" => "Unexpected argument(s): #{Enum.join(keys, ", ")}.",
        "arguments" => keys
      }
    }
  end

  defp tool_error_payload({:tool_scope_rejected, :read_only, tool}) do
    %{
      "error" => %{
        "code" => "tool_scope_rejected",
        "message" => "The reviewer tool scope is read-only; #{tool} is not available in this phase.",
        "tool" => tool,
        "scope" => "read_only"
      }
    }
  end

  defp tool_error_payload({:tool_scope_rejected, :qa, tool}) do
    %{
      "error" => %{
        "code" => "tool_scope_rejected",
        "message" => "The QA tool scope reads the issue and PR and attaches evidence files; #{tool} is not available. Report findings in your JSON verdict instead.",
        "tool" => tool,
        "scope" => "qa"
      }
    }
  end

  defp tool_error_payload({:tool_scope_rejected, _scope, "qa_android_" <> _rest = tool}) do
    %{
      "error" => %{
        "code" => "tool_scope_rejected",
        "message" => "#{tool} drives an Android app on Symphony's emulator for Auto Review QA and is only available to the QA agent.",
        "tool" => tool
      }
    }
  end

  defp tool_error_payload({:tool_scope_rejected, _scope, "qa_" <> _rest = tool}) do
    %{
      "error" => %{
        "code" => "tool_scope_rejected",
        "message" => "#{tool} drives a macOS app for Auto Review QA and is only available to the QA agent.",
        "tool" => tool
      }
    }
  end

  defp tool_error_payload({:qa_tool, code, message}) do
    %{"error" => %{"code" => code, "message" => message}}
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "code" => "missing_linear_api_token",
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status, body}) do
    %{
      "error" => %{
        "body" => body,
        "code" => "linear_api_status",
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_rate_limited, retry_ms}) do
    retry_at = retry_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    %{
      "error" => %{
        "code" => "linear_rate_limited",
        "message" => "Linear is rate-limiting Symphony; Linear calls are paused until #{retry_at}. Retry after that.",
        "retry_at" => retry_at
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "code" => "linear_api_request",
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:state_not_found, available_states}) do
    %{
      "error" => %{
        "code" => "state_not_found",
        "message" => "Linear workflow state not found. Available states: #{Enum.join(available_states, ", ")}.",
        "available_states" => available_states
      }
    }
  end

  defp tool_error_payload({:subissue_cap_reached, cap}) do
    %{
      "error" => %{
        "code" => "subissue_cap_reached",
        "message" => "This run already created #{cap} sub-issues, the per-run limit. List the remaining work in the workpad for a human to file instead.",
        "cap" => cap
      }
    }
  end

  defp tool_error_payload(:subissue_registry_unavailable) do
    %{
      "error" => %{
        "code" => "subissue_registry_unavailable",
        "message" => "Symphony has no per-run tool state for this session, so it cannot enforce the sub-issue cap and refused to create the issue."
      }
    }
  end

  defp tool_error_payload({:backlog_state_not_found, available_states}) do
    %{
      "error" => %{
        "code" => "backlog_state_not_found",
        "message" => "The current issue's team has no Backlog state, so no sub-issue was created. Available states: #{Enum.join(available_states, ", ")}.",
        "available_states" => available_states
      }
    }
  end

  defp tool_error_payload({:project_update_cap_reached, cap}) do
    %{
      "error" => %{
        "code" => "project_update_cap_reached",
        "message" => "This run already posted #{cap} project update, the per-run limit. Edit the existing update in Linear instead.",
        "cap" => cap
      }
    }
  end

  defp tool_error_payload(:project_update_registry_unavailable) do
    %{
      "error" => %{
        "code" => "project_update_registry_unavailable",
        "message" => "Symphony has no per-run tool state for this session, so it cannot enforce the project update cap and refused to post."
      }
    }
  end

  defp tool_error_payload({:invalid_human_action, message}) do
    %{"error" => %{"code" => "invalid_human_action", "message" => "linear_request_human_action: " <> message}}
  end

  defp tool_error_payload({:human_action_cap_reached, cap}) do
    %{
      "error" => %{
        "code" => "human_action_cap_reached",
        "message" => "This run already requested #{cap} human actions, the per-run limit. Put anything else in the blocker comment.",
        "cap" => cap
      }
    }
  end

  defp tool_error_payload(:human_actions_disabled) do
    %{
      "error" => %{
        "code" => "human_actions_disabled",
        "message" => "Human-action requests are turned off for this repository. Describe what the human must do in the blocker comment instead."
      }
    }
  end

  defp tool_error_payload(:issue_has_no_project) do
    %{"error" => %{"code" => "issue_has_no_project", "message" => "The current issue is not in a Linear project, so there is no project to post an update to."}}
  end

  defp tool_error_payload(:invalid_project_update_body) do
    %{"error" => %{"code" => "invalid_project_update_body", "message" => "linear_create_project_update requires a non-blank string `body`."}}
  end

  defp tool_error_payload(:invalid_project_update_health) do
    %{"error" => %{"code" => "invalid_project_update_health", "message" => "linear_create_project_update `health` must be onTrack, atRisk, or offTrack."}}
  end

  defp tool_error_payload(:invalid_subissue_title) do
    %{"error" => %{"code" => "invalid_subissue_title", "message" => "linear_create_subissue requires a non-blank string `title`."}}
  end

  defp tool_error_payload(:invalid_subissue_description) do
    %{"error" => %{"code" => "invalid_subissue_description", "message" => "linear_create_subissue requires a string `description`."}}
  end

  defp tool_error_payload(:invalid_subissue_priority) do
    %{"error" => %{"code" => "invalid_subissue_priority", "message" => "linear_create_subissue `priority` must be an integer from 0 to 4."}}
  end

  defp tool_error_payload(:invalid_subissue_blocked_by) do
    %{"error" => %{"code" => "invalid_subissue_blocked_by", "message" => "linear_create_subissue `blocked_by` must be a list of issue identifiers."}}
  end

  defp tool_error_payload({:blocked_by_not_sibling, unknown, siblings}) do
    %{
      "error" => %{
        "code" => "blocked_by_not_sibling",
        "message" => "linear_create_subissue `blocked_by` only accepts sub-issues of the current issue. Not a sub-issue: #{Enum.join(unknown, ", ")}. Nothing was created.",
        "unknown" => unknown,
        "sub_issues" => siblings
      }
    }
  end

  defp tool_error_payload({:blocked_by_relation_failed, identifier, blocker, reason}) do
    %{
      "error" => %{
        "code" => "blocked_by_relation_failed",
        "message" => "Created #{identifier}, but could not mark it blocked by #{blocker}, so it and any later `blocked_by` links are missing. Record them in the workpad for a human to add.",
        "identifier" => identifier,
        "blocker" => blocker,
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:invalid_comment_parent) do
    %{"error" => %{"code" => "invalid_comment_parent", "message" => "linear_add_comment `parent_id` must be the non-blank id of a comment on the current issue."}}
  end

  defp tool_error_payload(:invalid_subissue_identifier) do
    %{"error" => %{"code" => "invalid_subissue_identifier", "message" => "linear_update_subissue requires `identifier`, a sub-issue identifier such as TP-12."}}
  end

  defp tool_error_payload(:invalid_subissue_cancel_reason) do
    %{"error" => %{"code" => "invalid_subissue_cancel_reason", "message" => "linear_update_subissue `cancel_reason` must be a non-blank string."}}
  end

  defp tool_error_payload(:invalid_subissue_update) do
    %{
      "error" => %{
        "code" => "invalid_subissue_update",
        "message" => "linear_update_subissue needs `title`, `description` or `blocked_by` to change, or `cancel_reason` alone to cancel. Nothing was changed."
      }
    }
  end

  defp tool_error_payload({:not_a_subissue, identifier, sub_issues}) do
    %{
      "error" => %{
        "code" => "not_a_subissue",
        "message" => "#{identifier} is not a sub-issue of the current issue. Nothing was changed.",
        "sub_issues" => sub_issues
      }
    }
  end

  defp tool_error_payload({:subissue_not_in_backlog, identifier, state}) do
    %{
      "error" => %{
        "code" => "subissue_not_in_backlog",
        "message" => "#{identifier} is in #{state || "an unknown state"}, not Backlog: a person promoted it, so it is left as it is. Nothing was changed.",
        "state" => state
      }
    }
  end

  defp tool_error_payload({:canceled_state_not_found, states}) do
    %{
      "error" => %{
        "code" => "canceled_state_not_found",
        "message" => "The team has no Canceled state to move the sub-issue to. Nothing was changed.",
        "states" => states
      }
    }
  end

  defp tool_error_payload({:subissue_blocked_by_not_sibling, unknown, siblings}) do
    %{
      "error" => %{
        "code" => "blocked_by_not_sibling",
        "message" => "linear_update_subissue `blocked_by` only accepts other sub-issues of the current issue. Not one: #{Enum.join(unknown, ", ")}. Nothing was changed.",
        "unknown" => unknown,
        "sub_issues" => siblings
      }
    }
  end

  defp tool_error_payload({:subissue_blocked_by_failed, identifier, blocker, reason}) do
    %{
      "error" => %{
        "code" => "blocked_by_relation_failed",
        "message" => "Could not mark #{identifier} blocked by #{blocker}; it and any later `blocked_by` changes are missing. Retry, or record them in the workpad for a human to make.",
        "identifier" => identifier,
        "blocker" => blocker,
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:remove_blocked_by_failed, reason}) do
    %{
      "error" => %{
        "code" => "remove_blocked_by_failed",
        "message" => "Could not remove a blocked-by link the new list leaves out. Record it in the workpad for a human to remove.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:invalid_add_blocked_by) do
    %{"error" => %{"code" => "invalid_add_blocked_by", "message" => "linear_add_blocked_by requires `blocked_by`, a non-empty list of issue identifiers."}}
  end

  defp tool_error_payload({:blocked_by_not_found, unknown}) do
    %{
      "error" => %{
        "code" => "blocked_by_not_found",
        "message" => "linear_add_blocked_by could not find #{Enum.join(unknown, ", ")}. Nothing was linked.",
        "unknown" => unknown
      }
    }
  end

  defp tool_error_payload({:blocked_by_self, identifier}) do
    %{"error" => %{"code" => "blocked_by_self", "message" => "linear_add_blocked_by cannot mark #{identifier}, the current issue, as its own blocker. Nothing was linked."}}
  end

  defp tool_error_payload({:add_blocked_by_failed, blocker, reason}) do
    %{
      "error" => %{
        "code" => "add_blocked_by_failed",
        "message" => "Could not mark the current issue blocked by #{blocker}; it and any later `blocked_by` links are missing. Retry, or record them in the workpad for a human to add.",
        "blocker" => blocker,
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:subissue_not_returned) do
    %{"error" => %{"code" => "subissue_not_returned", "message" => "Linear did not return the created sub-issue."}}
  end

  defp tool_error_payload({:linear_mutation_failed, field, body}) do
    %{
      "error" => %{
        "code" => "linear_mutation_failed",
        "message" => "Linear `#{field}` mutation reported success=false.",
        "field" => field,
        "body" => body
      }
    }
  end

  defp tool_error_payload({:public_upload_denied_sensitive_filename, basename}) do
    %{
      "error" => %{
        "code" => "public_upload_denied_sensitive_filename",
        "message" => "Refused public Linear upload for sensitive filename #{inspect(basename)}. Attach privately or choose a non-sensitive artifact.",
        "filename" => basename
      }
    }
  end

  defp tool_error_payload({:private_upload_denied_sensitive_filename, basename}) do
    %{
      "error" => %{
        "code" => "private_upload_denied_sensitive_filename",
        "message" => "Refused private Linear upload for sensitive filename #{inspect(basename)}. Choose a non-sensitive artifact.",
        "filename" => basename
      }
    }
  end

  defp tool_error_payload({:public_extension_not_allowed, extension}) do
    %{
      "error" => %{
        "code" => "public_extension_not_allowed",
        "message" => "Refused public Linear upload for extension #{inspect(extension)}. Public uploads are restricted to configured image/PDF extensions by default.",
        "extension" => extension
      }
    }
  end

  defp tool_error_payload({:file_upload_too_large, details}) do
    %{
      "error" => %{
        "code" => "file_upload_too_large",
        "message" => "Linear file upload is too large for the selected visibility. Actual bytes: #{details.actual_bytes}; limit: #{details.max_bytes}.",
        "actual_bytes" => details.actual_bytes,
        "max_bytes" => details.max_bytes,
        "make_public" => details.make_public
      }
    }
  end

  defp tool_error_payload(:missing_github_origin_repo) do
    %{
      "error" => %{
        "code" => "missing_github_origin_repo",
        "message" => "Symphony could not resolve the configured origin GitHub repo for this workspace."
      }
    }
  end

  defp tool_error_payload(:missing_workspace) do
    %{
      "error" => %{
        "code" => "missing_workspace",
        "message" => "Symphony could not resolve the current workspace for this dynamic tool call."
      }
    }
  end

  defp tool_error_payload(:workspace_not_found) do
    %{
      "error" => %{
        "code" => "workspace_not_found",
        "message" => "The current workspace path does not exist."
      }
    }
  end

  defp tool_error_payload(:missing_current_branch) do
    %{
      "error" => %{
        "code" => "missing_current_branch",
        "message" => "Symphony could not resolve the current git branch for this workspace."
      }
    }
  end

  defp tool_error_payload({:unsupported_for_ssh_worker, :github_push_branch}) do
    %{
      "error" => %{
        "code" => "unsupported_for_ssh_worker",
        "message" => "github_push_branch is not supported for SSH worker sessions. Symphony brokers GitHub PR API operations only; git push must use a separate secure push path."
      }
    }
  end

  defp tool_error_payload({:unsupported_for_ssh_worker, :github_fetch_origin}) do
    %{
      "error" => %{
        "code" => "unsupported_for_ssh_worker",
        "message" => "github_fetch_origin is not supported for SSH worker sessions. Symphony only brokers local workspace fetches through this tool."
      }
    }
  end

  defp tool_error_payload({:git_fetch_failed, status, output}) do
    %{
      "error" => %{
        "code" => "git_fetch_failed",
        "message" => "git fetch origin failed.",
        "status" => status,
        "output" => output
      }
    }
  end

  defp tool_error_payload({:push_check_required, reason, %{"command" => command, "result_file" => result_file, "head" => head} = details}) do
    found =
      case reason do
        :missing -> "There is no `#{result_file}`."
        :stale -> "`#{result_file}` holds the result for #{short_sha(details["recorded_head"])}, not for this commit."
        :invalid -> "`#{result_file}` is not a push check result."
      end

    %{
      "error" => %{
        "code" => "push_check_required",
        "message" =>
          "Push refused: this push changes files the repository's push check covers, and the check has not passed for " <>
            "#{short_sha(head)}. #{found} Commit your work, run `#{command}` in your shell (it runs the checks in your " <>
            "sandbox and records the result), fix anything it reports, then call github_push_branch again.",
        "command" => command,
        "result_file" => result_file,
        "head" => head
      }
    }
  end

  defp tool_error_payload({:push_check_failed, %{"command" => command, "result_file" => result_file, "head" => head, "output" => output}}) do
    %{
      "error" => %{
        "code" => "push_check_failed",
        "message" =>
          "Push refused: the repository's push check failed for #{short_sha(head)}:\n#{output}\n" <>
            "Run `#{command}` in your shell to see each check's output. Fix what it names, commit, run the " <>
            "command again, then call github_push_branch again.",
        "command" => command,
        "result_file" => result_file,
        "head" => head
      }
    }
  end

  defp tool_error_payload({:issue_not_in_merging_state, state_name}) do
    %{
      "error" => %{
        "code" => "issue_not_in_merging_state",
        "message" => "github_merge_pull_request only merges after a human moves the issue to `Merging`. The issue is in #{inspect(state_name)}; do not move it yourself to get past this."
      }
    }
  end

  defp tool_error_payload({:merging_requires_human_approval, state_name}) do
    %{
      "error" => %{
        "code" => "merging_requires_human_approval",
        "message" => "linear_update_state cannot move the issue to #{inspect(state_name)}. Moving an issue to `Merging` is how a human approves the merge, so a human has to do it in Linear."
      }
    }
  end

  defp tool_error_payload({:in_review_set_by_auto_review, state_name, auto_review_state}) do
    %{
      "error" => %{
        "code" => "in_review_set_by_auto_review",
        "message" =>
          "linear_update_state cannot move the issue to #{inspect(state_name)}. " <>
            "Symphony moves the issue to #{auto_review_state} once the PR is open; leave the state as it is."
      }
    }
  end

  defp tool_error_payload({:waiting_on_sub_issues_state_requires_human_approval, state_name}) do
    %{
      "error" => %{
        "code" => "waiting_on_sub_issues_state_requires_human_approval",
        "message" =>
          "linear_update_state cannot move the issue to #{inspect(state_name)}. Moving a `breakdown` parent there " <>
            "approves its plan and promotes its sub-tickets, so a human does it; move the parent to `In Review` instead."
      }
    }
  end

  defp tool_error_payload({:pull_request_not_open, state}) do
    %{
      "error" => %{
        "code" => "pull_request_not_open",
        "message" => "The pull request for the current workspace branch is #{inspect(state)}, so it cannot be merged."
      }
    }
  end

  defp tool_error_payload({:checks_not_passing, outcome}) do
    %{
      "error" => %{
        "code" => "checks_not_passing",
        "message" => "Pull request checks are not all passing yet. Wait for pending checks to finish or fix the failures, then merge.",
        "reason" => inspect(outcome)
      }
    }
  end

  defp tool_error_payload(:no_failed_github_actions_run) do
    %{
      "error" => %{
        "code" => "no_failed_github_actions_run",
        "message" => "No failed GitHub Actions run with a log was found for the current pull request."
      }
    }
  end

  defp tool_error_payload(:invalid_failed_run_log_max_bytes) do
    %{
      "error" => %{
        "code" => "invalid_failed_run_log_max_bytes",
        "message" => "github.failed_run_log_max_bytes must be a positive integer."
      }
    }
  end

  defp tool_error_payload(:truncated_comment_body) do
    %{
      "error" => %{
        "code" => "truncated_comment_body",
        "message" =>
          "The comment body contains Symphony's `[... truncated by Symphony: ... exceeded N characters ...]` marker, so it was copied from a cut read and would delete the text past the cut. Read the comment again with `linear_get_comments` and send its full text."
      }
    }
  end

  defp tool_error_payload(:invalid_comment_id) do
    %{
      "error" => %{
        "code" => "invalid_comment_id",
        "message" => "github_reply_to_review_comment requires a non-blank inline review comment id (integer or numeric string)."
      }
    }
  end

  defp tool_error_payload(:invalid_body) do
    %{
      "error" => %{
        "code" => "invalid_body",
        "message" => "Dynamic GitHub tools require a string `body` argument."
      }
    }
  end

  defp tool_error_payload(:invalid_reply_payload) do
    %{
      "error" => %{
        "code" => "invalid_reply_payload",
        "message" => "GitHub did not return a JSON object payload for the inline-comment reply."
      }
    }
  end

  defp tool_error_payload({:invalid_reply_payload, message}) do
    %{
      "error" => %{
        "code" => "invalid_reply_payload",
        "message" => "GitHub returned an invalid JSON payload for the inline-comment reply: #{message}."
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "code" => inspect(reason),
        "message" => "Dynamic tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp short_sha(sha), do: String.slice(sha, 0, 12)
end
