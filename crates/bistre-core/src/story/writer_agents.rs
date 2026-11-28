//! Writing & Roleplay Helper Agents and Turn Routers:
//! - Two-Phase Prewriter (a writing brief, with questions for the author, before prose)
//! - Continuity Librarian (editable Era Summaries + contradiction audit)
//! - Group Scene Turn Router (`natural` | `round_robin` | `manual`)
//! - Inline Rewrite Laser Tools (`rewrite` | `expand` | `shorten` | `polish`).

use bistre_protocol::CharacterCardRecord;

/// Supported inline selection rewrite operations inside the Manuscript Canvas.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaserEditMode {
    Rewrite,
    Expand,
    Shorten,
    Polish,
}

impl LaserEditMode {
    pub fn parse(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "expand" => Self::Expand,
            "shorten" => Self::Shorten,
            "polish" => Self::Polish,
            _ => Self::Rewrite,
        }
    }
}

/// Selects the next active speaker in a multi-character Group Scene without overlapping replies.
/// - `manual`: returns `manual_speaker_id` if valid, else first character
/// - `round_robin`: rotates strictly after `last_speaker_id`
/// - `natural`: prioritizes explicit name/nickname mention in `latest_user_message`, falling back to round-robin.
pub fn select_group_scene_speaker<'a>(
    characters: &'a [CharacterCardRecord],
    mode: &str,
    latest_user_message: &str,
    last_speaker_id: Option<&str>,
    manual_speaker_id: Option<&str>,
) -> Option<&'a CharacterCardRecord> {
    if characters.is_empty() {
        return None;
    }

    if mode == "manual"
        && let Some(target_id) = manual_speaker_id
        && let Some(found) = characters.iter().find(|c| c.id == target_id)
    {
        return Some(found);
    }

    if mode == "natural" {
        let lower = latest_user_message.to_ascii_lowercase();
        for c in characters {
            let name_hit =
                !c.name.trim().is_empty() && lower.contains(&c.name.to_ascii_lowercase());
            let nick_hit =
                !c.nickname.trim().is_empty() && lower.contains(&c.nickname.to_ascii_lowercase());
            if name_hit || nick_hit {
                return Some(c);
            }
        }
    }

    // Round-robin fallback avoiding immediate double-speaking when >= 2 characters are present.
    if let Some(last_id) = last_speaker_id
        && let Some(pos) = characters.iter().position(|c| c.id == last_id)
    {
        return Some(&characters[(pos + 1) % characters.len()]);
    }

    characters.first()
}

/// A writing tool's request: fixed instructions (sent as the system prompt) and the text they
/// act on (sent as the user message).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WriterPrompt {
    pub system: &'static str,
    pub user: String,
}

const PREWRITER_PROMPT: &str = "Write a writing brief for the scene below, before any prose is written. \
List: 1. the emotional arc and the order of the beats; 2. each fact from the story memory the scene must keep; \
3. at most two questions for the author, each about a motive or a detail the beats do not state. \
Reply in the language of the beats, as a numbered list. Write no prose of the scene.";

/// The prewriter brief for a scene: its title, beats, and the chat's story memory.
pub fn prewriter_prompt(scene_title: &str, beats: &str, story_memory: &str) -> WriterPrompt {
    let memory = if story_memory.trim().is_empty() {
        "(none)"
    } else {
        story_memory.trim()
    };
    WriterPrompt {
        system: PREWRITER_PROMPT,
        user: format!(
            "[Scene]\n{}\n\n[Story memory]\n{memory}\n\n[Beats]\n{}",
            scene_title.trim(),
            beats.trim()
        ),
    }
}

/// The line that opens the contradiction list in a continuity librarian reply.
pub const CONTRADICTIONS_HEADING: &str = "Contradictions:";

const LIBRARIAN_PROMPT: &str = "Summarize the chapter below for the story's record. \
First write at most three bullets on what the chapter changes for good: the plot, relationships, \
and what characters own or carry. Then write the line \"Contradictions:\" followed by one bullet \
for each statement in the chapter that conflicts with the earlier summaries, naming both, or \
nothing when there is none. Reply in the chapter's language.";

/// The continuity librarian's request: an era summary of a chapter, checked against the
/// summaries of the chapters before it.
pub fn continuity_librarian_prompt(
    chapter_title: &str,
    chapter_text: &str,
    prior_era_summaries: &str,
) -> WriterPrompt {
    let prior = if prior_era_summaries.trim().is_empty() {
        "(none)"
    } else {
        prior_era_summaries.trim()
    };
    WriterPrompt {
        system: LIBRARIAN_PROMPT,
        user: format!(
            "[Chapter]\n{}\n\n[Earlier summaries]\n{prior}\n\n[Chapter text]\n{}",
            chapter_title.trim(),
            chapter_text.trim()
        ),
    }
}

/// Splits a librarian reply into the era summary and its contradiction bullets. A reply with
/// no [`CONTRADICTIONS_HEADING`] line is all summary.
pub fn split_librarian_reply(reply: &str) -> (String, Vec<String>) {
    let Some((summary, rest)) = reply.split_once(CONTRADICTIONS_HEADING) else {
        return (reply.trim().to_owned(), Vec::new());
    };
    let contradictions = rest
        .lines()
        .map(|l| l.trim().trim_start_matches(['-', '*', '\u{2022}']).trim())
        .filter(|l| !l.is_empty())
        .map(ToOwned::to_owned)
        .collect();
    (summary.trim().to_owned(), contradictions)
}

/// The inline rewrite tool's request for the highlighted excerpt of a scene.
pub fn laser_edit_prompt(
    mode: LaserEditMode,
    selected_excerpt: &str,
    surrounding_context: &str,
) -> WriterPrompt {
    let system = match mode {
        LaserEditMode::Rewrite => {
            "Rewrite the highlighted excerpt in new words. Keep its events, facts, point of view, \
             and tense. Reply with the replacement text alone, in the excerpt's language."
        }
        LaserEditMode::Expand => {
            "Expand the highlighted excerpt with sensory detail and the point-of-view character's \
             thoughts. Keep its events, point of view, and tense. Reply with the replacement text \
             alone, in the excerpt's language."
        }
        LaserEditMode::Shorten => {
            "Shorten the highlighted excerpt. Keep every event and fact it states, its point of \
             view, and its tense. Reply with the replacement text alone, in the excerpt's language."
        }
        LaserEditMode::Polish => {
            "Improve the rhythm, word choice, and dialogue of the highlighted excerpt. Keep its \
             meaning, point of view, tense, and the author's voice. Reply with the replacement \
             text alone, in the excerpt's language."
        }
    };
    WriterPrompt {
        system,
        user: format!(
            "[Scene, for context only]\n{}\n\n[Highlighted excerpt]\n{}",
            surrounding_context.trim(),
            selected_excerpt.trim()
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writer_prompts_follow_the_prompt_rules() {
        let mut systems: Vec<&str> = [
            LaserEditMode::Rewrite,
            LaserEditMode::Expand,
            LaserEditMode::Shorten,
            LaserEditMode::Polish,
        ]
        .into_iter()
        .map(|mode| laser_edit_prompt(mode, "x", "y").system)
        .collect();
        systems.push(prewriter_prompt("t", "b", "").system);
        systems.push(continuity_librarian_prompt("t", "x", "").system);
        for system in systems {
            let breaks = crate::test_support::prompt_rule_breaks(system);
            assert_eq!(breaks, Vec::<String>::new(), "{system}");
        }
    }

    /// The summary stops at the contradictions line; each bullet after it is one item.
    #[test]
    fn a_librarian_reply_splits_into_summary_and_contradictions() {
        let (summary, found) = split_librarian_reply(
            "- Lyra loses the map.\n- Bram joins the crew.\nContradictions:\n- Chapter 2 says the map burned.\n",
        );
        assert_eq!(summary, "- Lyra loses the map.\n- Bram joins the crew.");
        assert_eq!(found, vec!["Chapter 2 says the map burned.".to_owned()]);
        let (only, none) = split_librarian_reply("- Nothing changes.\nContradictions:\n");
        assert_eq!(only, "- Nothing changes.");
        assert_eq!(none, Vec::<String>::new());
        assert_eq!(split_librarian_reply("plain").0, "plain");
    }

    #[test]
    fn group_router_handles_natural_mentions_and_round_robin() {
        let chars = vec![
            CharacterCardRecord {
                id: "c1".to_owned(),
                name: "Lyra".to_owned(),
                ..CharacterCardRecord::default()
            },
            CharacterCardRecord {
                id: "c2".to_owned(),
                name: "Bram".to_owned(),
                nickname: "Captain".to_owned(),
                ..CharacterCardRecord::default()
            },
        ];

        // Direct nickname mention routes naturally to Bram.
        let natural = select_group_scene_speaker(
            &chars,
            "natural",
            "Hey Captain, check the compass!",
            Some("c2"),
            None,
        );
        assert_eq!(natural.map(|c| c.id.as_str()), Some("c2"));

        // Unmentioned turn rotates round-robin to Lyra.
        let rotated = select_group_scene_speaker(
            &chars,
            "natural",
            "The wind is shifting.",
            Some("c2"),
            None,
        );
        assert_eq!(rotated.map(|c| c.id.as_str()), Some("c1"));

        // The rewrite request carries the mode's instruction and the excerpt.
        let prompt = laser_edit_prompt(LaserEditMode::Expand, "She opened the door.", "Hallway.");
        assert!(prompt.system.starts_with("Expand"));
        assert!(prompt.user.ends_with("She opened the door."));
    }
}
