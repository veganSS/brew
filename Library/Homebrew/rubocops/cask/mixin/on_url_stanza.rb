# typed: strict
# frozen_string_literal: true

module RuboCop
  module Cop
    module Cask
      # Common functionality for checking url stanzas.
      module OnUrlStanza
        extend Forwardable
        include CaskHelp

        sig { override.params(cask_block: T.nilable(RuboCop::Cask::AST::CaskBlock)).void }
        def on_cask(cask_block)
          @cask_block = T.let(cask_block, T.nilable(RuboCop::Cask::AST::CaskBlock))

          toplevel_stanzas.select(&:url?).each do |stanza|
            on_url_stanza(stanza)
          end
        end

        private

        sig { returns(T.nilable(RuboCop::Cask::AST::CaskBlock)) }
        attr_reader :cask_block

        def_delegators :cask_block,
                       :toplevel_stanzas
      end
    end
  end
end
