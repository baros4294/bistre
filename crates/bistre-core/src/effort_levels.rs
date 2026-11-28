//! The thinking-effort levels one model accepts, from its catalog entry (Spec 02). A model
//! with no catalog data keeps every level; the 400 heal ladder still steps down at run time.

use bistre_protocol::ReasoningEffort;

/// The levels the effort picker offers, lowest first. `ModelDefault` and `Adaptive` are
/// modes, not levels, so every model keeps them.
pub const EFFORT_LEVELS: [ReasoningEffort; 6] = [
    ReasoningEffort::Off,
    ReasoningEffort::Low,
    ReasoningEffort::Medium,
    ReasoningEffort::High,
    ReasoningEffort::ExtraHigh,
    ReasoningEffort::Max,
];

/// A set of [`EFFORT_LEVELS`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(transparent)]
pub struct EffortSet(u8);

impl EffortSet {
    /// Every level: what a model without catalog data offers.
    pub const ALL: Self = Self(0b11_1111);

    const fn bit(level: ReasoningEffort) -> u8 {
        match level {
            ReasoningEffort::Off => 1,
            ReasoningEffort::Low => 2,
            ReasoningEffort::Medium => 4,
            ReasoningEffort::High => 8,
            ReasoningEffort::ExtraHigh => 16,
            ReasoningEffort::Max => 32,
            ReasoningEffort::ModelDefault | ReasoningEffort::Adaptive => 0,
        }
    }

    /// The level a catalog name means (`none`, `minimal`, `low`, ... `max`); other names are
    /// not levels.
    #[must_use]
    pub fn level_of(name: &str) -> Option<ReasoningEffort> {
        let level = ReasoningEffort::parse(name);
        (Self::bit(level) != 0).then_some(level)
    }

    pub fn insert(&mut self, level: ReasoningEffort) {
        self.0 |= Self::bit(level);
    }

    pub fn remove(&mut self, level: ReasoningEffort) {
        self.0 &= !Self::bit(level);
    }

    #[must_use]
    pub const fn contains(self, level: ReasoningEffort) -> bool {
        self.0 & Self::bit(level) != 0
    }

    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    /// The levels in the set, lowest first.
    pub fn levels(self) -> impl Iterator<Item = ReasoningEffort> {
        EFFORT_LEVELS.into_iter().filter(move |l| self.contains(*l))
    }

    /// What a run sends for `wanted`: the highest level in the set at or below it, else the
    /// lowest level in the set. A mode (`ModelDefault`, `Adaptive`) and an empty set pass
    /// `wanted` through.
    #[must_use]
    pub fn clamp(self, wanted: ReasoningEffort) -> ReasoningEffort {
        if Self::bit(wanted) == 0 || self.is_empty() || self.contains(wanted) {
            return wanted;
        }
        let rank = EFFORT_LEVELS.iter().position(|l| *l == wanted);
        let below = self
            .levels()
            .filter(|l| EFFORT_LEVELS.iter().position(|x| x == l) < rank)
            .last();
        below.or_else(|| self.levels().next()).unwrap_or(wanted)
    }
}

impl FromIterator<ReasoningEffort> for EffortSet {
    fn from_iter<I: IntoIterator<Item = ReasoningEffort>>(levels: I) -> Self {
        let mut set = Self::default();
        for level in levels {
            set.insert(level);
        }
        set
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ReasoningEffort::{Adaptive, ExtraHigh, High, Low, Max, Medium, ModelDefault, Off};

    #[test]
    fn a_level_the_model_lacks_steps_down_then_up() {
        let set: EffortSet = [Low, Medium, High].into_iter().collect();
        assert_eq!(set.clamp(Max), High);
        assert_eq!(set.clamp(ExtraHigh), High);
        assert_eq!(set.clamp(Medium), Medium);
        assert_eq!(set.clamp(Off), Low);
        assert_eq!(set.clamp(Adaptive), Adaptive);
        assert_eq!(set.clamp(ModelDefault), ModelDefault);
        assert_eq!(EffortSet::default().clamp(Max), Max);
    }

    #[test]
    fn catalog_names_map_to_levels() {
        assert_eq!(EffortSet::level_of("none"), Some(Off));
        assert_eq!(EffortSet::level_of("minimal"), Some(Low));
        assert_eq!(EffortSet::level_of("xhigh"), Some(ExtraHigh));
        assert_eq!(EffortSet::level_of("adaptive"), None);
        assert_eq!(EffortSet::level_of("turbo"), None);
        assert_eq!(EffortSet::ALL.levels().count(), EFFORT_LEVELS.len());
    }
}
