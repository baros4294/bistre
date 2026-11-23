//! Writing & Roleplay Helper Agents and Turn Routers (Wave E):
//! - Two-Phase Prewriter (clarifying writing brief before prose)
//! - Background Continuity Librarian (editable Era Summaries + contradiction audit, Wallet Shield aware)
//! - Group Scene Turn Router (`natural` | `round_robin` | `manual`)
//! - Continue, Impersonate, and Inline Rewrite Laser Tools (`rewrite` | `expand` | `shorten` | `polish`).

use bistre_protocol::{CharacterCardRecord, NodeRecord};

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

/// Builds a Two-Phase Prewriter prompt that proposes a structured scene plan & clarifies intent before prose.
pub fn build_prewriter_prompt(scene_title: &str, beats: &str, story_memory: &str) -> String {
    format!(
        "Before writing final prose for scene \"{scene_title}\", produce a concise Writing Brief:\n\
         1. Emotional arc and pacing beat order.\n\
         2. Key continuity anchors from Story Memory ({story_memory}).\n\
         3. Up to 2 brief clarifying questions if any motivation or detail is ambiguous.\n\n\
         Scene Beats:\n{beats}"
    )
}

/// Builds a Background Continuity Librarian audit prompt to synthesize an editable Era Summary
/// and surface any timeline or character contradictions.
pub fn build_continuity_librarian_prompt(
    chapter_title: &str,
    chapter_text: &str,
    prior_era_summaries: &str,
) -> String {
    format!(
        "Act as a Continuity Librarian for \"{chapter_title}\".\n\
         1. Write a concise 3-bullet Era Summary capturing permanent plot, relationship, and inventory changes.\n\
         2. List any contradictions against prior Era Summaries ({prior_era_summaries}), or state 'None'.\n\n\
         Chapter Text:\n{chapter_text}"
    )
}

/// Builds a seamless `Continue` prompt extending the last assistant passage without repetition.
pub fn build_continue_prompt(last_passage: &str) -> String {
    let tail: String = last_passage
        .chars()
        .rev()
        .take(320)
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    format!(
        "Continue seamlessly from the exact end of the previous passage without repeating prior sentences. \
         Maintain identical POV, tense, and voice.\n\nPrevious ending:\n{tail}"
    )
}

/// Builds an `Impersonate` prompt drafting a reply in the active User Persona voice.
pub fn build_impersonate_prompt(
    persona_name: &str,
    persona_desc: &str,
    recent: &[NodeRecord],
) -> String {
    let last_line = recent.last().map_or("", |n| n.content.as_str());
    format!(
        "Draft the next response strictly from {persona_name}'s perspective ({persona_desc}). \
         Write only {persona_name}'s dialogue/actions in response to:\n{last_line}"
    )
}

/// Builds an Inline Rewrite Laser Tool prompt (`rewrite` | `expand` | `shorten` | `polish`).
pub fn build_laser_edit_prompt(
    mode: LaserEditMode,
    selected_excerpt: &str,
    surrounding_context: &str,
) -> String {
    let instruction = match mode {
        LaserEditMode::Rewrite => {
            "Rewrite the highlighted excerpt with fresher phrasing while preserving plot meaning."
        }
        LaserEditMode::Expand => {
            "Expand the highlighted excerpt with grounded sensory detail and character interiority."
        }
        LaserEditMode::Shorten => {
            "Tighten and shorten the highlighted excerpt for sharper pacing without losing key beats."
        }
        LaserEditMode::Polish => {
            "Polish prose rhythm, word choice, and dialogue cadence while staying faithful to the author's voice."
        }
    };
    format!(
        "{instruction}\nReturn ONLY the replacement text for the highlighted excerpt.\n\n\
         Context:\n{surrounding_context}\n\n\
         Highlighted Excerpt:\n{selected_excerpt}"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

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

        // Laser edit builder includes exact instruction and excerpt.
        let prompt =
            build_laser_edit_prompt(LaserEditMode::Expand, "She opened the door.", "Hallway.");
        assert!(prompt.contains("Expand"));
        assert!(prompt.contains("She opened the door."));
    }
}
