require 'spec_helper'

# Proposed specs for guards that survived mutation testing.
# Guards that survived mutation testing: each example below goes red if the guard it names
# is removed from lib/.
describe 'guards not previously covered' do
  class GuardWidget
    attr_accessor :a
    def initialize(a = nil) = @a = a
    def ==(other) = other.is_a?(GuardWidget) && other.a == a
  end

  class RejectingSetting < RailsSettings::Base
    self.table_name = 'settings'
    validate { errors.add(:var, 'rejected') if var.to_s.start_with?('rejected') }
  end

  before(:each) do
    Setting.unscoped.delete_all
    Rails.cache.clear
  end

  # ---------- S15: Setting.get_all must not return another record's rows ----------
  describe '.get_all on the global class' do
    it 'returns only unscoped rows, never another record\'s' do
      user = User.create!(login: 'getall', password: 'x')
      Setting.global_only = 'g'
      user.settings.scoped_only = 's'

      expect(Setting.get_all.keys).to include('global_only')
      expect(Setting.get_all.keys).not_to include('scoped_only')
    end
  end

  # ---------- C09 / C10: ScopedSettings.thing_scoped must filter on BOTH columns ----------
  describe '.get_all on a scoped class' do
    it 'does not leak another record of the same type' do
      a = Partner.create!(code: 'ga_a')
      b = Partner.create!(code: 'ga_b')
      a.settings.mine = 'yes'
      b.settings.theirs = 'no'

      expect(a.settings.get_all.keys).to include('partner.mine')
      expect(a.settings.get_all.keys).not_to include('partner.theirs')
    end

    it 'does not leak another model that happens to share the id' do
      shared_id = [Partner.maximum(:id).to_i, User.maximum(:id).to_i].max + 1
      partner = Partner.new(code: 'twin'); partner.id = shared_id; partner.save!
      twin = User.new(login: 'twin', password: 'x'); twin.id = shared_id; twin.save!

      partner.settings.mine = 'yes'
      twin.settings.theirs = 'no'

      expect(partner.settings.get_all.keys).to include('partner.mine')
      expect(partner.settings.get_all.keys).not_to include('theirs')
    end
  end

  # ---------- S04: the row read path must go through YAMLCoder ----------
  describe 'decoding a settings row' do
    it 'refuses a class outside the allow-list' do
      row = Setting.unscoped.create!(var: 'evil')
      row.update_column(:value, GuardWidget.new(1).to_yaml)

      expect { Setting.unscoped.find(row.id).value }.to raise_error(Psych::DisallowedClass)
    end
  end

  # ---------- D09: the defaults file must go through YAMLCoder too ----------
  describe 'decoding the defaults file' do
    it 'refuses a class outside the allow-list' do
      path = File.expand_path('../../tmp/guard-app.yml', __FILE__)
      File.write(path, "test:\n  widget: !ruby/object:GuardWidget\n    a: 1\n")
      allow(RailsSettings::Default).to receive(:source_path).and_return(path)

      expect { RailsSettings::Default.new }.to raise_error(Psych::DisallowedClass)
    ensure
      FileUtils.rm_f(path)
    end
  end

  # ---------- E01 / E07 / E10: the Extend scopes must bind thing_type ----------
  describe 'Extend scopes vs. another model sharing the id' do
    before do
      @u = User.create!(login: 'xmodel', password: 'x')
      @p = Partner.new(code: 'xmodel')
      @p.id = @u.id
      @p.save! unless Partner.exists?(@u.id)
      @p = Partner.find(@u.id)
      @p.settings.color = 'partner-red'   # thing_type Partner, thing_id == @u.id
    end

    it 'with_settings ignores another model\'s rows' do
      expect(User.with_settings).not_to include(@u)
    end

    it 'without_settings still counts the user as having none' do
      expect(User.without_settings).to include(@u)
    end

    it 'with_settings_for ignores another model\'s rows' do
      expect(User.with_settings_for('partner.color')).to be_empty
    end
  end

  # ---------- E03: DISTINCT ----------
  describe 'with_settings' do
    it 'returns a record once however many settings it has' do
      u = User.create!(login: 'multi', password: 'x')
      u.settings.a = 1
      u.settings.b = 2

      expect(User.with_settings.to_a.count { |r| r.id == u.id }).to eq 1
    end
  end

  # ---------- B10 / C08 / S43 / E02: STI must resolve to base_class ----------
  describe 'single-table inheritance' do
    it 'stores, reads, keys and joins STI rows under the base class' do
      admin = AdminUser.create!(login: 'sti', password: 'x')
      admin.settings.color = 'red'

      row = Setting.unscoped.find_by(thing_id: admin.id, var: 'color')
      expect(row.thing_type).to eq 'User'                                    # S43
      expect(Setting.cache_key('color', admin)).to include("/User-#{admin.id}/") # B10
      expect(admin.settings.get_all.keys).to include('color')                  # C08
      expect(AdminUser.with_settings).to include(admin)                        # E02
    end
  end

  # ---------- B17 / S34 / S45 / S46 / S47: rails_initialized? ----------
  describe 'before Rails has finished initializing' do
    it 'serves the YAML default without touching the cache or the database' do
      allow(Rails.application).to receive(:initialized?).and_return(false)
      expect(Rails.cache).not_to receive(:fetch)

      queries = count_setting_queries { expect(Setting.str).to eq 'hello in test' }
      expect(queries).to eq 0
    end

    it 'is false when there is no application object yet' do
      allow(Rails).to receive(:application).and_return(nil)
      expect(Setting.rails_initialized?).to be_falsey
    end
  end

  # ---------- S18 / S21: the get_all prefix is a prefix, not a substring ----------
  describe '.get_all prefix matching' do
    it 'anchors the prefix at the start of the stored key' do
      Setting['config.color']    = 1
      Setting['my.config.other'] = 2

      expect(Setting.get_all('config').keys).to eq ['config.color']
    end

    it 'anchors the prefix at the start of a default key too' do
      allow(RailsSettings::Default).to receive(:instance)
        .and_return({ 'config.a' => 1, 'my.config.b' => 2 })

      expect(Setting.get_all('config').keys).not_to include('my.config.b')
    end
  end

  # ---------- S12: destroy tells you the key was not there ----------
  describe '.destroy' do
    it 'raises SettingNotFound for a key that was never set' do
      expect { Setting.destroy(:never_set_anywhere) }
        .to raise_error(RailsSettings::Settings::SettingNotFound, /never_set_anywhere/)
    end
  end

  # ---------- S49 / S50: merge! ----------
  describe '.merge!' do
    it 'lets the new value win on a key that already exists' do
      Setting.mhash = { a: 1, b: 2 }

      expect(Setting.merge!(:mhash, b: 3)).to eq(a: 1, b: 3)
      expect(Setting.mhash).to eq(a: 1, b: 3)
    end

    it 'refuses to merge into a value that is not a hash' do
      Setting.not_a_hash = 'a string'

      expect { Setting.merge!(:not_a_hash, a: 1) }.to raise_error(TypeError)
    end
  end

  # ---------- S32: a rejected write must not look like a successful one ----------
  describe '[]= when the record will not save' do
    it 'raises instead of silently dropping the write' do
      expect { RejectingSetting.rejected_key = 1 }.to raise_error(ActiveRecord::RecordInvalid)
      expect(Setting.unscoped.find_by(var: 'rejected_key')).to be_nil
    end
  end

  # ---------- D01 / D12: the defaults file must actually be there and usable ----------
  describe 'RailsSettings::Default.enabled?' do
    it 'is false when the configured file does not exist' do
      allow(RailsSettings::Default).to receive(:source_path).and_return('/nonexistent/app.yml')

      expect(RailsSettings::Default.enabled?).to be_falsey
    end
  end

  describe 'an empty defaults file' do
    it 'yields no defaults rather than raising' do
      path = File.expand_path('../../tmp/guard-empty.yml', __FILE__)
      File.write(path, '')
      allow(RailsSettings::Default).to receive(:source_path).and_return(path)

      expect(RailsSettings::Default.new).to eq({})
    ensure
      FileUtils.rm_f(path)
    end
  end

  # ---------- D14: Settings.source keeps the first path it is given ----------
  describe '.source' do
    it 'keeps the first configured path' do
      RailsSettings::Default.instance_variable_set(:@source, nil)
      RailsSettings::Settings.source('/tmp/first.yml')

      expect(RailsSettings::Default.source_path).to eq '/tmp/first.yml'
      RailsSettings::Default.source            # a getter-style call must not wipe it
      expect(RailsSettings::Default.source_path).to eq '/tmp/first.yml'
    ensure
      RailsSettings::Default.instance_variable_set(:@source, nil)
    end
  end

  # Covers expire_cache being reached from the in-transaction invalidation hook. The
  # after_commit :expire_cache registration itself is covered in cache_invalidation_spec.rb.
  describe 'cache invalidation on a plain ActiveRecord update' do
    it 'reflects a row updated outside []=' do
      Setting.direct_update = 'old'
      expect(Setting.direct_update).to eq 'old'       # now cached

      Setting.unscoped.find_by(var: 'direct_update').update!(value: 'new')

      expect(Setting.direct_update).to eq 'new'
    end
  end

  # ---------- S10: the dynamic writer silently drops the scope object ----------
  describe 'KNOWN divergence: the dynamic writer cannot scope a write' do
    # `Setting.color(partner)` reads the partner's row, but no writer spelling writes one.
    # `send('color=', 'red', partner)` sees args[0] == 'red', so scope_object stays nil and
    # the value lands on a global row; the only call that does set scope_object --
    # `send('color=', partner)` -- uses that same argument as the VALUE, serialising the
    # record itself. Pinned so that fixing the asymmetry is a deliberate change.
    it 'writes a global row when the scope object follows the value' do
      partner = Partner.create!(code: 'dynwriter')
      Setting.send('dyn_color=', 'red', partner)

      row = Setting.unscoped.find_by(var: 'dyn_color')
      expect(row.thing_type).to be_nil
      expect(row.thing_id).to be_nil
      expect(Setting.dyn_color(partner)).to be_nil
    end

    it 'serialises the record itself when the scope object comes first' do
      partner = Partner.create!(code: 'dynwriter2')
      expect { Setting.send('mm_color=', partner) }.to raise_error(ArgumentError, /cannot store a value of type Partner/)

      # Now rejected at the call site rather than written and found undecodable on every read.
      expect(Setting.unscoped.find_by(var: 'partner.mm_color')).to be_nil
    end
  end

  # ---------- B38: an explicit object outranks the thread settings_scope ----------
  describe '.scoped_key precedence' do
    it 'lets an explicit object override the thread settings_scope' do
      acct = Account.create!(code: 'prec')
      acct.settings                                    # settings_scope 'acct' is now on this thread

      expect(RailsSettings::ScopedSettings.scoped_key('color', acct)).to eq 'account.color'
      expect(RailsSettings::ScopedSettings.scoped_key('color')).to eq 'acct.color'
    end
  end

  # ---------- F02 / F06 / F08 / F11: configuration ----------
  describe 'RailsSettings.config' do
    after do
      RailsSettings.config.yaml_permitted_classes = nil
      RailsSettings.config.yaml_unsafe_load = nil
      RailsSettings.config.yaml_aliases = nil
    end

    it 'permits Symbol on its own account, not only via ActiveRecord' do
      allow(ActiveRecord).to receive(:yaml_column_permitted_classes).and_return([])

      expect(RailsSettings.config.yaml_permitted_classes).to include(Symbol)
    end

    it 'picks up whatever ActiveRecord permits' do
      RailsSettings.config.yaml_permitted_classes = nil  # drop the memo BEFORE stubbing
      allow(ActiveRecord).to receive(:yaml_column_permitted_classes).and_return([BigDecimal])

      expect(RailsSettings.config.yaml_permitted_classes).to include(BigDecimal)
    end

    it 'follows ActiveRecord.use_yaml_unsafe_load when nothing is configured here' do
      allow(ActiveRecord).to receive(:use_yaml_unsafe_load).and_return(true)

      expect(RailsSettings.config.yaml_unsafe_load).to be true
    end

    it 'honours yaml_aliases = false' do
      RailsSettings.config.yaml_aliases = false

      expect { RailsSettings::YAMLCoder.load("a: &x 1\nb: *x\n") }
        .to raise_error(Psych::AliasesNotEnabled)
    end
  end
end
